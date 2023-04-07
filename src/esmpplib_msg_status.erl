-module(esmpplib_msg_status).

-include_lib("smpp_parser/src/smpp_base.hrl").

-export([
    to_string/1
]).

to_string(?MESSAGE_STATE_DELIVERED) ->
    <<"DELIVRD">>;
to_string(?MESSAGE_STATE_UNDELIVERABLE) ->
    <<"UNDELIV">>;
to_string(?MESSAGE_STATE_REJECTED) ->
    <<"REJECTD">>;
to_string(?MESSAGE_STATE_ACCEPTED) ->
    <<"ACCEPTD">>;
to_string(?MESSAGE_STATE_ENROUTE) ->
    <<"ENROUTE">>;
to_string(?MESSAGE_STATE_EXPIRED) ->
    <<"EXPIRED">>;
to_string(_) ->
    <<"UNKNOWN">>.
