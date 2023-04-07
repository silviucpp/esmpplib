-module(esmpplib_pending_request_queue).

-record(state, {
    seq_map,
    exp_queue
}).

-export([
    new/0,
    push/3,
    ack/2,
    has_items/1,
    pop_next_expired_ack/1,
    peek_next_expired_ack/1
]).

new() ->
    {ok, Q} = epqueue:new(),
    #state{exp_queue = Q, seq_map = maps:new()}.

push(SeqNum, ExpireTimeoutMs, #state{seq_map = SeqMap, exp_queue = ExpTimeQueue} = State) ->
    {ok, ItemRef} = epqueue:insert(ExpTimeQueue, SeqNum, esmpplib_time:now_msec()+ExpireTimeoutMs),
    State#state{seq_map = maps:put(SeqNum, ItemRef, SeqMap)}.

ack(SeqNum, #state{seq_map = SeqMap, exp_queue = ExpTimeQueue} = State) ->
    case maps:take(SeqNum, SeqMap) of
        {ItemRef, NewSeqMap} ->
            true = epqueue:remove(ExpTimeQueue, ItemRef),
            State#state{seq_map = NewSeqMap};
        _ ->
            State
    end.

has_items(#state{exp_queue = ExpTimeQueue}) ->
    epqueue:size(ExpTimeQueue) =/= 0.

pop_next_expired_ack(#state{seq_map = SeqMap, exp_queue = ExpTimeQueue} = State) ->
    case epqueue:pop(ExpTimeQueue) of
        {ok, SeqNum, ExpireTime} ->
            {ok, {SeqNum, ExpireTime}, State#state{seq_map = maps:remove(SeqNum, SeqMap)}};
        _ ->
            {ok, null, State}
    end.

peek_next_expired_ack(#state{exp_queue = ExpTimeQueue}) ->
    epqueue:peek(ExpTimeQueue).