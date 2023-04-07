-module(pending_request_queue_test).

-include_lib("smpp_parser/src/smpp_globals.hrl").
-include_lib("eunit/include/eunit.hrl").

queue_test() ->
    Q = esmpplib_pending_request_queue:new(),
    ?assertEqual(false, esmpplib_pending_request_queue:has_items(Q)),
    Q1 = esmpplib_pending_request_queue:push(2, 10000, Q),
    Q2 = esmpplib_pending_request_queue:push(3, 10000, Q1),
    ?assertEqual(true, esmpplib_pending_request_queue:has_items(Q2)),
    Q3 = esmpplib_pending_request_queue:ack(2, Q2),
    Q4 = esmpplib_pending_request_queue:ack(3, Q3),
    ?assertEqual(false, esmpplib_pending_request_queue:has_items(Q4)).
