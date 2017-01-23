%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s2a).

-behaviour(gtp_api).

-compile({parse_transform, do}).

-export([validate_options/1, init/2, request_spec/2,
	 handle_request/4,
	 handle_cast/2, handle_info/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%%====================================================================
%% API
%%====================================================================

-define('Recovery',					{v2_recovery, 0}).
-define('IMSI',						{v2_international_mobile_subscriber_identity, 0}).
%% -define('MSISDN',					{v2_ms_international_pstn_isdn_number, 0}).
-define('PDN Address Allocation',			{v2_pdn_address_allocation, 0}).
-define('RAT Type',					{v2_rat_type, 0}).
-define('Sender F-TEID for Control Plane',		{v2_fully_qualified_tunnel_endpoint_identifier, 0}).
-define('Access Point Name',				{v2_access_point_name, 0}).
-define('Bearer Contexts to be created',		{v2_bearer_context, 0}).
%% -define('Bearer Contexts to be modified',		   {v2_bearer_context, 0}).
%% -define('Protocol Configuration Options',		{v2_protocol_configuration_options, 0}).
%% -define('IMEI',						{v2_imei, 0}).

-define('EPS Bearer ID',                                {v2_eps_bearer_id, 0}).
-define('S2a-U TWAN F-TEID',                            {v2_fully_qualified_tunnel_endpoint_identifier, 6}).

request_spec(v2, create_session_request) ->
    [{?'IMSI',							conditional},
     {?'RAT Type',						mandatory},
     {?'Sender F-TEID for Control Plane',			mandatory},
     {?'Access Point Name',					mandatory},
     {?'Bearer Contexts to be created',				mandatory}];
request_spec(v2, delete_session_request) ->
    [];
request_spec(v2, _) ->
    [].

validate_options(Options) ->
    lager:debug("GGSN S2a Options: ~p", [Options]),
    ergw_config:validate_options(fun validate_option/2, Options).

validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

init(_Opts, State) ->
    {ok, State}.

handle_cast({path_restart, Path}, #{context := #context{path = Path} = Context} = State) ->
    dp_delete_pdp_context(Context),
    pdn_release_ip(Context, State),
    {stop, normal, State};
handle_cast({path_restart, _Path}, State) ->
    {noreply, State};

handle_cast({packet_in, _GtpPort, _IP, _Port, #gtp{type = error_indication}},
	    #{context := Context} = State) ->
    dp_delete_pdp_context(Context),
    pdn_release_ip(Context, State),
    {stop, normal, State};

handle_cast({packet_in, _GtpPort, _IP, _Port, _Msg}, State) ->
    lager:warning("packet_in not handled (yet): ~p", [_Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

handle_request(_ReqKey, _Msg, true, State) ->
%% resent request
    {noreply, State};

handle_request(_ReqKey,
	       #gtp{type = create_session_request,
		    ie = #{?'Recovery'                        := Recovery,
			   ?'Sender F-TEID for Control Plane' := FqCntlTEID,
			   ?'Bearer Contexts to be created' :=
			       #v2_bearer_context{group = #{
						    ?'EPS Bearer ID'     := EBI,
						    ?'S2a-U TWAN F-TEID' := FqDataTEID       %% S2a TEI Instance
						   }}
			  } = IEs},
	       _Resent,
	       #{context := Context0} = State) ->

    PAA = maps:get(?'PDN Address Allocation', IEs, undefined),

    Context1 = update_context_tunnel_ids(FqCntlTEID, FqDataTEID, Context0),
    Context2 = update_context_from_gtp_req(IEs, Context1),
    Context3 = gtp_path:bind(Recovery, Context2),

    {VRF, _VRFOpts} = select_vrf(Context3),

    Context = assign_ips(PAA, Context3#context{vrf = VRF}),
    gtp_context:register_remote_context(Context),
    dp_create_pdp_context(Context),

    ResponseIEs0 = create_session_response(EBI, Context),
    ResponseIEs = gtp_v2_c:build_recovery(Context, Recovery /= undefined, ResponseIEs0),
    Response = {create_session_response, Context#context.remote_control_tei, ResponseIEs},
    {ok, Response, State#{context => Context}};

handle_request(_ReqKey,
	       #gtp{type = delete_session_request, ie = IEs}, _Resent,
	       #{context := Context} = State0) ->

    %% according to 3GPP TS 29.274, the F-TEID is not part of the Delete Session Request
    %% on S2a. However, Cisco iWAG on CSR 1000v does include it. Since we get it, lets
    %% validate it for now.
    FqTEI = maps:get(?'Sender F-TEID for Control Plane', IEs, undefined),

    #context{remote_control_tei = RemoteCntlTEI} = Context,

    Result =
	do([error_m ||
	       match_context(35, Context, FqTEI),
	       return({RemoteCntlTEI, request_accepted, State0})
	   ]),

    case Result of
	{ok, {ReplyTEI, ReplyIEs, State}} ->
	    dp_delete_pdp_context(Context),
	    pdn_release_ip(Context, State),
	    Reply = {delete_session_response, ReplyTEI, ReplyIEs},
	    {stop, Reply, State};

	{error, {ReplyTEI, ReplyIEs}} ->
	    Response = {delete_session_response, ReplyTEI, ReplyIEs},
	    {reply, Response, State0};

	{error, ReplyIEs} ->
	    Response = {delete_session_response, 0, ReplyIEs},
	    {reply, Response, State0}
    end;

handle_request(_ReqKey, _Msg, _Resent, State) ->
    {noreply, State}.

%%%===================================================================
%%% Helper functions
%%%===================================================================
ip2prefix({IP, Prefix}) ->
    <<Prefix:8, (gtp_c_lib:ip2bin(IP))/binary>>.

match_context(_Type, _Context, undefined) ->
    error_m:return(ok);
match_context(Type,
	      #context{
		 remote_control_ip  = RemoteCntlIP,
		 remote_control_tei = RemoteCntlTEI} = Context,
	      #v2_fully_qualified_tunnel_endpoint_identifier{
		 instance       = 0,
		 interface_type = Type,
		 key            = RemoteCntlTEI,
		 ipv4           = RemoteCntlIPBin} = IE) ->
    case gtp_c_lib:bin2ip(RemoteCntlIPBin) of
	RemoteCntlIP ->
	    error_m:return(ok);
	_ ->
	    lager:error("match_context: IP address mismatch, ~p, ~p, ~p",
			[Type, lager:pr(Context, ?MODULE), lager:pr(IE, ?MODULE)]),
	    error_m:fail([#v2_cause{v2_cause = context_not_found}])
    end;
match_context(Type, Context, IE) ->
    lager:error("match_context: context not found, ~p, ~p, ~p",
		[Type, lager:pr(Context, ?MODULE), lager:pr(IE, ?MODULE)]),
    error_m:fail([#v2_cause{v2_cause = context_not_found}]).

pdn_alloc(#v2_pdn_address_allocation{type = ipv4v6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary, IP4:4/binary>>}) ->
    {gtp_c_lib:bin2ip(IP4), {gtp_c_lib:bin2ip(IP6Prefix), IP6PrefixLen}};
pdn_alloc(#v2_pdn_address_allocation{type = ipv4,
				     address = << IP4:4/binary>>}) ->
    {gtp_c_lib:bin2ip(IP4), undefined};
pdn_alloc(#v2_pdn_address_allocation{type = ipv6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary>>}) ->
    {undefined, {gtp_c_lib:bin2ip(IP6Prefix), IP6PrefixLen}}.

encode_paa({IPv4,_}, undefined) ->
    encode_paa(ipv4, gtp_c_lib:ip2bin(IPv4), <<>>);
encode_paa(undefined, IPv6) ->
    encode_paa(ipv6, <<>>, ip2prefix(IPv6));
encode_paa({IPv4,_}, IPv6) ->
    encode_paa(ipv4v6, gtp_c_lib:ip2bin(IPv4), ip2prefix(IPv6)).

encode_paa(Type, IPv4, IPv6) ->
    #v2_pdn_address_allocation{type = Type, address = <<IPv6/binary, IPv4/binary>>}.

pdn_release_ip(#context{ms_v4 = MSv4, ms_v6 = MSv6}, #{gtp_port := GtpPort}) ->
    vrf:release_pdp_ip(GtpPort, MSv4, MSv6).

select_vrf(#context{apn = APN}) ->
    {ok, {VRF, VRFOpts}} = ergw:vrf(APN),
    {VRF, VRFOpts}.

update_context_tunnel_ids(#v2_fully_qualified_tunnel_endpoint_identifier{
			     key  = RemoteCntlTEI,
			     ipv4 = RemoteCntlIP},
			  #v2_fully_qualified_tunnel_endpoint_identifier{
			     key  = RemoteDataTEI,
			     ipv4 = RemoteDataIP
			    }, Context) ->
    Context#context{
      remote_control_ip  = gtp_c_lib:bin2ip(RemoteCntlIP),
      remote_control_tei = RemoteCntlTEI,
      remote_data_ip     = gtp_c_lib:bin2ip(RemoteDataIP),
      remote_data_tei    = RemoteDataTEI
     }.

get_context_from_req(?'Access Point Name', #v2_access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #v2_international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(_, _, Context) ->
    Context.

update_context_from_gtp_req(Request, Context) ->
    maps:fold(fun get_context_from_req/3, Context, Request).

dp_args(#context{vrf = VRF, ms_v4 = {MSv4,_}}) ->
    {vrf, VRF, MSv4}.

dp_create_pdp_context(Context) ->
    Args = dp_args(Context),
    gtp_dp:create_pdp_context(Context, Args).

%% dp_update_pdp_context(NewContext, OldContext) ->
%%     %% TODO: only do that if New /= Old
%%     dp_delete_pdp_context(OldContext),
%%     dp_create_pdp_context(NewContext).

dp_delete_pdp_context(Context) ->
    Args = dp_args(Context),
    gtp_dp:delete_pdp_context(Context, Args).

assign_ips(PAA, #context{apn = APN, local_control_tei = LocalTEI} = Context) ->
    {ReqMSv4, ReqMSv6} = pdn_alloc(PAA),
    {ok, MSv4, MSv6} = vrf:allocate_pdp_ip(APN, LocalTEI, ReqMSv4, ReqMSv6),
    Context#context{ms_v4 = MSv4, ms_v6 = MSv6}.

create_session_response(EBI,
			#context{control_port = #gtp_port{ip = LocalIP},
				 local_control_tei = LocalTEI,
				 ms_v4 = MSv4, ms_v6 = MSv6}) ->
    [#v2_cause{v2_cause = request_accepted},
     #v2_fully_qualified_tunnel_endpoint_identifier{
	instance = 1,
	interface_type = 36,          %% S2a PGW GTP-C
	key = LocalTEI,
	ipv4 = gtp_c_lib:ip2bin(LocalIP)
       },
     encode_paa(MSv4, MSv6),
     %% #v2_protocol_configuration_options{config = {0,
     %% 						[{ipcp,'CP-Configure-Ack',0,
     %% 						  [{ms_dns1,<<8,8,8,8>>},{ms_dns2,<<0,0,0,0>>}]}]}},
     #v2_bearer_context{
	group=[#v2_cause{v2_cause = request_accepted},
	       EBI,
	       #v2_bearer_level_quality_of_service{
		  pl=15,
		  pvi=0,
		  label=9,maximum_bit_rate_for_uplink=0,
		  maximum_bit_rate_for_downlink=0,
		  guaranteed_bit_rate_for_uplink=0,
		  guaranteed_bit_rate_for_downlink=0},
	       #v2_fully_qualified_tunnel_endpoint_identifier{
		  instance = 5,                  %% S2a TEI Instance
		  interface_type = 37,           %% S2a PGW GTP-U
		  key = LocalTEI,
		  ipv4 = gtp_c_lib:ip2bin(LocalIP)}]}].
