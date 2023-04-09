-module(integrity_test_SUITE).

-include_lib("stdlib/include/assert.hrl").
-include_lib("smpp_parser/src/smpp_base.hrl").
-include("esmpplib.hrl").

-behavior(esmpplib_connection).

-compile(export_all).

all() -> [
    {group, integrity_test}
].

groups() -> [
    {integrity_test, [sequence], [
        submit_sm_sync_test,
        submit_sm_async_test,
        multi_part_messages_test,
        query_sm_test
    ]}
].

suite() ->
    [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
    application:ensure_all_started(esmpplib),
    ok = ect_config:start(),

    CtTests = esmpplib_utils:get_env(ct_tests),
    ok = lists:foreach(fun({K, V}) -> ect_config:set(K, V) end, CtTests),

    Pools = esmpplib_utils:get_env(pools),
    CtPool = esmpplib_utils:lookup(ct_pool, Pools),
    Options = esmpplib_utils:lookup(connection_options, CtPool),
    ok = ect_config:set(connection_options, Options),

    Config.

end_per_suite(_Config) ->
    ok = ect_config:stop().

on_submit_sm_response_successful(MessageRef, MessageId, NrParts) ->
    ?INFO_MSG("### on_submit_sm_response_successful -> ~p", [[MessageRef, MessageId, NrParts]]),
    ect_config:set({on_submit_sm_response_successful, MessageRef}, [MessageId, NrParts]).

on_submit_sm_response_failed(MessageRef, Error) ->
    ?INFO_MSG("### on_submit_sm_response_failed -> ~p", [[MessageRef, Error]]),
    ect_config:set({on_submit_sm_response_failed, MessageRef}, Error).

on_delivery_report(MessageId, From, To, SubmitDate, DlrDate, Status, ErrorCode) ->
    ?INFO_MSG("### on_delivery_report -> ~p", [[MessageId, From, To, SubmitDate, DlrDate, Status, ErrorCode]]),
    ect_config:set({dlr,MessageId}, [From, To, SubmitDate, DlrDate, Status, ErrorCode]).

on_query_sm_response(MessageId, Success, Response) ->
    ?INFO_MSG("### on_query_sm_response -> ~p", [[MessageId, Success, Response]]),
    ect_config:set({query_sm_resp,MessageId}, [Success, Response]).

on_connection_change_notification(Id, Pid, IsConnected) ->
    ?INFO_MSG("### on_connection_change_notification -> ~p", [[Id, Pid, IsConnected]]),
    ect_config:set({connection_status, Id, Pid}, IsConnected).

submit_sm_sync_test(_Config) ->
    {ok, P} = new_connection(submit_sm_sync_test, #{callback_module => ?MODULE}),

    % send failed message

    {error, Reason} = esmpplib_connection:submit_sm(P, <<"INFO">>, <<"">>, <<"invalid message">>),
    ?assertEqual({submit_failed, ?ESME_RINVDSTADR, <<"ESME_RINVDSTADR">>}, Reason),

    % send message successful

    Src = <<"INFO">>,
    Dst = <<"40743616112">>,
    {ok, MessageId, PartsNumber} = esmpplib_connection:submit_sm(P, Src, Dst, <<"hello world!">>),
    ?assertEqual(true, is_binary(MessageId)),
    ?assertEqual(1, PartsNumber),

    % check dlr

    check_dlr(MessageId, Src, Dst),

    ok = esmpplib_connection:stop(P).

submit_sm_async_test(_Config) ->
    {ok, P} = new_connection(submit_sm_async_test, #{callback_module => ?MODULE}),

    % send failed message

    MessageRef = make_ref(),
    ?assertEqual(ok, esmpplib_connection:submit_sm_async(P, MessageRef, <<"INFO">>, <<"">>, <<"invalid message">>)),
    ?assertEqual(ok, ect_utils:wait_for_config_is_set({on_submit_sm_response_failed, MessageRef})),
    ?assertEqual({error, {submit_failed, ?ESME_RINVDSTADR, <<"ESME_RINVDSTADR">>}}, ect_config:get({on_submit_sm_response_failed, MessageRef})),

    % send message successful

    MessageRef2 = make_ref(),
    Src = <<"INFO">>,
    Dst = <<"40743616112">>,
    ?assertEqual(ok, esmpplib_connection:submit_sm_async(P, MessageRef2, Src, Dst, <<"hello world">>)),
    ?assertEqual(ok, ect_utils:wait_for_config_is_set({on_submit_sm_response_successful, MessageRef2})),
    [MessageId, NrParts] = ect_config:get({on_submit_sm_response_successful, MessageRef2}),
    ?assertEqual(true, is_binary(MessageId)),
    ?assertEqual(1, NrParts),

    % check dlr

    check_dlr(MessageId, Src, Dst),

    ok = esmpplib_connection:stop(P).

multi_part_messages_test(_Config) ->
    {ok, P} = new_connection(multi_part_messages_test, #{callback_module => ?MODULE}),

    % send message successful -> sync

    Src = <<"INFO">>,
    Dst = <<"40743616112">>,
    Msg = <<"123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456789123456|">>,
    MsgUcs2 = <<"`123456789`123456789`123456789`123456789`123456789`123456789`12345678s`">>,

    {ok, MessageId, PartsNumber} = esmpplib_connection:submit_sm(P, Src, Dst, Msg),
    ?assertEqual(true, is_binary(MessageId)),
    ?assertEqual(2, PartsNumber),

    % send message successful -> async

    MessageRef = make_ref(),
    ?assertEqual(ok,  esmpplib_connection:submit_sm_async(P, MessageRef, Src, Dst, MsgUcs2)),
    ?assertEqual(ok, ect_utils:wait_for_config_is_set({on_submit_sm_response_successful, MessageRef})),
    [MessageId2, NrParts2] = ect_config:get({on_submit_sm_response_successful, MessageRef}),
    ?assertEqual(true, is_binary(MessageId2)),
    ?assertEqual(2, NrParts2),

    % check dlr

    check_dlr(MessageId, Src, Dst),
    check_dlr(MessageId2, Src, Dst),

    ok = esmpplib_connection:stop(P).

query_sm_test(_Config) ->
    {ok, P} = new_connection(multi_part_messages_test, #{callback_module => ?MODULE}),

    Src = <<"INFO">>,
    Dst = <<"40743616112">>,
    Msg = <<"hello world">>,

    {ok, MessageId, PartsNumber} = esmpplib_connection:submit_sm(P, Src, Dst, Msg),
    ?assertEqual(true, is_binary(MessageId)),
    ?assertEqual(1, PartsNumber),

    check_dlr(MessageId, Src, Dst),

    % query_sm sync

    QuerySMSupported = ect_config:get(query_sm_supported),

    Result = esmpplib_connection:query_sm(P, MessageId),

    case QuerySMSupported of
        false ->
            ?assertEqual({error,{query_failed, ?ESME_RQUERYFAIL, <<"ESME_RQUERYFAIL">>}}, Result);
        _ ->
            ?assertEqual(false, Result)
    end,

    % query_sm async

    ?assertEqual(ok, esmpplib_connection:query_sm_async(P, MessageId)),
    ?assertEqual(ok, ect_utils:wait_for_config_is_set({query_sm_resp, MessageId})),

    case QuerySMSupported of
        false ->
            ?assertEqual([false, {error,{query_failed, ?ESME_RQUERYFAIL, <<"ESME_RQUERYFAIL">>}}], ect_config:get({query_sm_resp, MessageId}));
        _ ->
            ?assertEqual(false, ect_config:get({query_sm_resp, MessageId}))
    end,

    ok = esmpplib_connection:stop(P).

% internals

check_dlr(MessageId, Src, Dst) ->
    ?assertEqual(ok, ect_utils:wait_for_config_is_set({dlr, MessageId})),
    [From, To, SubmitDate, DoneDate, Status, ErrorCode] = ect_config:get({dlr, MessageId}),
    ?assertEqual(From, Src),
    ?assertEqual(To, Dst),
    ?assertEqual(true, is_integer(SubmitDate)),
    ?assertEqual(true, is_integer(DoneDate)),
    ?assertEqual(<<"DELIVRD">>, Status),
    ?assertEqual(0, ErrorCode).

new_connection(Id, Opts) ->
    BaseOtions = maps:from_list([{id, Id}|ect_config:get(connection_options)]),
    {ok, P} = esmpplib_connection:start_link(maps:merge(BaseOtions, Opts)),
    ?assertEqual(ok , ect_utils:wait_for_config_value({connection_status, Id, P}, true)),
    ?assertEqual({ok, true}, esmpplib_connection:is_connected(P)),
    {ok, P}.