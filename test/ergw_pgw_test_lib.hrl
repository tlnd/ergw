%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-ifndef(ERGW_PGW_NO_IMPORTS).

-import('ergw_pgw_test_lib', [make_echo_request/1,
			      create_session/1, create_session/2,
			      delete_session/2,
			      modify_bearer_tei_update/2,
			      modify_bearer_ra_update/2,
			      change_notification_with_tei/2,
			      change_notification_without_tei/2,
			      suspend_notification/2,
			      resume_notification/2]).

-endif.

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).