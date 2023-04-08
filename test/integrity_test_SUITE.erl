-module(integrity_test_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("smpp_parser/src/smpp_base.hrl").
-include("esmpplib.hrl").

-define(HOST, "smscsim.smpp.org").
-define(PORT, 2775).
-define(TRANSPORT, tcp).
-define(INTERFACE_VERSION, <<"5.0">>).
-define(USERNAME, <<"username">>).
-define(PASSWORD, <<"password">>).

-behavior(esmpplib_connection).

-compile(export_all).

all() -> [
    {group, integrity_test}
].

groups() -> [
    {integrity_test, [sequence], [
        sync_api_test
    ]}
].

suite() ->
    [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
    application:ensure_all_started(esmpplib),
    ok = ect_config:start(),
    {ok, _} = ect_event_manager:start_link(),
    Config.

end_per_suite(_Config) ->
    ok = ect_config:stop().

on_submit_sm_response_successful(MessageRef, MessageId, NrParts) ->
    ?INFO_MSG("### on_submit_sm_response_successful -> ~p", [[MessageRef, MessageId, NrParts]]),
    ect_event_manager:notify(on_submit_sm_response_successful, [MessageRef, MessageId, NrParts]).

on_submit_sm_response_failed(MessageRef, Error) ->
    ?INFO_MSG("### on_submit_sm_response_failed -> ~p", [[MessageRef, Error]]),
    ect_event_manager:notify(on_submit_sm_response_failed, [MessageRef, Error]).

on_delivery_report(MessageId, From, To, SubmitDate, DlrDate, Status, ErrorCode) ->
    ?INFO_MSG("### on_delivery_report -> ~p", [[MessageId, From, To, SubmitDate, DlrDate, Status, ErrorCode]]),
    ect_config:set({dlr,MessageId}, [From, To, SubmitDate, DlrDate, Status, ErrorCode]).

on_connection_change_notification(Id, Pid, IsConnected) ->
    ?INFO_MSG("### on_connection_change_notification -> ~p", [[Id, Pid, IsConnected]]),
    ect_config:set({connection_status, Id, Pid}, IsConnected).

sync_api_test(_Config) ->
    {ok, P} = new_connection(sync_api_test, #{callback_module => ?MODULE}),

    % send failed message

    {error, Reason} = esmpplib_connection:submit_sm(P, <<"INFO">>, <<"">>, <<"invalid message">>),
    ?assertEqual({submit_failed, ?ESME_RINVDSTADR, <<"ESME_RINVDSTADR">>}, Reason),

    % send message successful

    Src = <<"INFO">>,
    Dst = <<"1234567890">>,
    {ok, MessageId, PartsNumber} = esmpplib_connection:submit_sm(P, Src, Dst, <<"hello world!">>),
    ?assertEqual(true, is_binary(MessageId)),
    ?assertEqual(1, PartsNumber),

    % test delivery report

    ?assertEqual(ok, ect_utils:wait_for_config_is_set({dlr, MessageId})),
    [From, To, SubmitDate, DoneDate, Status, ErrorCode] = ect_config:get({dlr, MessageId}),
    ?assertEqual(From, Src),
    ?assertEqual(To, Dst),
    ?assertEqual(true, is_integer(SubmitDate)),
    ?assertEqual(true, is_integer(DoneDate)),
    ?assertEqual(<<"DELIVRD">>, Status),
    ?assertEqual(0, ErrorCode),

    ok = esmpplib_connection:stop(P).

% internals

new_connection(Id, Opts) ->
    Config = #{
        id => Id,
        host => ?HOST,
        port => ?PORT,
        transport => ?TRANSPORT,
        interface_version => ?INTERFACE_VERSION,
        system_id => ?USERNAME,
        password => ?PASSWORD
    },
    {ok, P} = esmpplib_connection:start_link(maps:merge(Config, Opts)),
    ?assertEqual(ok , ect_utils:wait_for_config_value({connection_status, Id, P}, true)),
    ?assertEqual({ok, true}, esmpplib_connection:is_connected(P)),
    {ok, P}.