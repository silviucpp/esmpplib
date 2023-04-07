-module(esmpplib_connection).

-include("esmpplib.hrl").
-include_lib("smpp_parser/src/smpp_globals.hrl").
-include_lib("smpp_parser/src/smpp_base.hrl").

-define(IS_SOCKET_CLOSED_TAG(T), T == tcp_closed orelse T == ssl_closed).
-define(IS_SOCKET_ERROR_TAG(T), T == tcp_error orelse T == ssl_error).
-define(MAKE_RESPONSE(CmdId), CmdId bor 16#80000000).
-define(SMPP_SEQ_NUM_MAX, 16#7FFFFFFF).
-define(IS_BIND_RESPONSE(C), C == ?COMMAND_ID_BIND_RECEIVER_RESP orelse C == ?COMMAND_ID_BIND_TRANSCEIVER_RESP orelse C == ?COMMAND_ID_BIND_TRANSMITTER_RESP ).
-define(REPLY_MSG(CommandId, FromPid, Async, Args), {CommandId, FromPid, Async, Args}).

-define(SOCKET_DEFAULT_OPTIONS, [
    {mode, binary},
    {packet, raw},
    {active, false},
    {keepalive, true},
    {nodelay, true},
    {delay_send, false},
    {send_timeout, 10000},
    {send_timeout_close, true}
]).

-behaviour(gen_server).

-callback on_submit_sm_response_successful(MessageRef::any(), MessageId::binary(), NrParts::non_neg_integer()) ->
    any().

-callback on_submit_sm_response_failed(MessageRef::any(), Error::any()) ->
    any().

-callback on_delivery_report(MessageId::binary(), SrcAddress::binary(), DstAddress::binary(), SubmitDate::timestamp(), DoneDate::timestamp(), Status::msg_status(), ErrorCode::non_neg_integer()) ->
    any().

-callback on_query_sm_response(MessageId::binary(), Success::boolean(), Response::[{any(), any()}]|{error, reason()}) ->
    any().

-optional_callbacks([
    on_submit_sm_response_successful/3,
    on_submit_sm_response_failed/2,
    on_delivery_report/7,
    on_query_sm_response/3
]).

-export([
    start_link/1,
    submit_sm/4,
    submit_sm_async/5,
    query_sm/2,
    query_sm_async/2,

    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    id,
    transport,
    options,
    reconnect_attempts = 0,

    reply_map = #{},
    pending_req_queue = esmpplib_pending_request_queue:new(),
    socket,
    parser,
    seq_num = 1,
    ref_num = 1,
    binding_mode,
    enquire_link_timer,
    binding_timer,
    pending_requests_timeout_timer
}).

start_link(Options) ->
    gen_server:start_link(?MODULE, Options, []).

submit_sm(Pid, SrcAddr, DstAddr, Message) ->
    esmpplib_utils:safe_call(Pid, {submit_sm, undefined, SrcAddr, DstAddr, Message, false}, infinity).

submit_sm_async(Pid, MessageRef, SrcAddr, DstAddr, Message) ->
    esmpplib_utils:safe_call(Pid, {submit_sm, MessageRef, SrcAddr, DstAddr, Message, true}).

query_sm(Pid, MessageId) ->
    esmpplib_utils:safe_call(Pid, {query_sm, MessageId, false}, infinity).

query_sm_async(Pid, MessageId) ->
    esmpplib_utils:safe_call(Pid, {query_sm, MessageId, true}).

% gen_server callbacks

init(Options0) ->
    Options = maps:merge(default_options(), Options0),
    Transport = get_transport(maps:get(transport, Options)),
    Id = maps:get(id, Options, maps:get(host, Options)),
    schedule_reconnect(0, Options),
    {ok, #state{id = Id, transport = Transport, options = Options}}.

handle_call({submit_sm, MessageRef, SrcAddr, DstAddr, Message, Async}, FromPid, #state{
    id = Id,
    binding_mode = BindingMode,
    transport = Transport,
    socket= Socket,
    seq_num = SeqNum,
    ref_num = RefNumber,
    reply_map = ReplyMap,
    pending_req_queue = PendingReqQueue,
    pending_requests_timeout_timer = PendingReqTimeoutTimer,
    options = Options } = State) ->

    case BindingMode of
        undefined ->
            {reply, {error, not_connected}, State};
        receiver ->
            {reply, {error, <<"receiver only binding mode.">>}, State};
        _ ->
            RequestTimeoutMs = maps:get(pending_requests_timeout, Options),

            case submit_sm_options(SrcAddr, DstAddr, Message, RefNumber, Options) of
                {ok, SubmitSmOption} ->
                    send_command(Transport, Socket, {?COMMAND_ID_SUBMIT_SM, ?ESME_ROK, SeqNum, SubmitSmOption}),
                    NewPendingReqQueue = esmpplib_pending_request_queue:push(SeqNum, RequestTimeoutMs, PendingReqQueue),
                    NewState = State#state{
                        seq_num = get_next_sequence_number(SeqNum),
                        reply_map = maps:put(SeqNum, ?REPLY_MSG(?COMMAND_ID_SUBMIT_SM, FromPid, Async, [MessageRef, 1]), ReplyMap),
                        pending_req_queue = NewPendingReqQueue,
                        pending_requests_timeout_timer = schedule_pending_request_timeout(NewPendingReqQueue, PendingReqTimeoutTimer)
                    },
                    case Async of
                        true ->
                            {reply, ok, NewState};
                        _ ->
                            {noreply, NewState}
                    end;
                {ok, TotalParts, SubmitSmListReversed} ->
                    % please not the parts here are in reverse order (this is by design)
                    % we store the last sequence_number which is associated with the first part.

                    {NewSeqNum, LastSentSeqNum, NewPendingReqQueue} = lists:foldl(fun(SubmitSmOption, {NewSq, _, PrQ} ) ->
                        send_command(Transport, Socket, {?COMMAND_ID_SUBMIT_SM, ?ESME_ROK, NewSq, SubmitSmOption}),
                        {get_next_sequence_number(NewSq), NewSq, esmpplib_pending_request_queue:push(NewSq, RequestTimeoutMs, PrQ)}
                    end, {SeqNum, SeqNum, PendingReqQueue}, SubmitSmListReversed),

                    NewState = State#state{
                        seq_num = NewSeqNum,
                        ref_num = get_next_ref_num(RefNumber),
                        reply_map = maps:put(LastSentSeqNum, ?REPLY_MSG(?COMMAND_ID_SUBMIT_SM, FromPid, Async, [MessageRef, TotalParts]), ReplyMap),
                        pending_req_queue = NewPendingReqQueue,
                        pending_requests_timeout_timer = schedule_pending_request_timeout(NewPendingReqQueue, PendingReqTimeoutTimer)
                    },

                    case Async of
                        true ->
                            {reply, ok, NewState};
                        _ ->
                            {noreply, NewState}
                    end;
                Error ->
                    ?ERROR_MSG("connection_id: ~p submit_sm from: ~p to: ~p msg: ~p failed with: ~p", [Id, SrcAddr, DstAddr, Message, Error]),
                    {reply, Error, State}
            end
    end;
handle_call({query_sm, MessageId, Async}, FromPid, #state{
    binding_mode = BindingMode,
    transport = Transport,
    socket= Socket,
    seq_num = SeqNum,
    reply_map = ReplyMap,
    pending_req_queue = PendingReqQueue,
    pending_requests_timeout_timer = PendingReqTimeoutTimer,
    options = Options } = State) ->
    case BindingMode of
        undefined ->
            {reply, {error, not_connected}, State};
        _ ->
            RequestTimeoutMs = maps:get(pending_requests_timeout, Options),
            send_command(Transport, Socket, {?COMMAND_ID_QUERY_SM, ?ESME_ROK, SeqNum, [{message_id, MessageId}]}),
            NewPendingReqQueue = esmpplib_pending_request_queue:push(SeqNum, RequestTimeoutMs, PendingReqQueue),
            NewState = State#state{
                seq_num = get_next_sequence_number(SeqNum),
                reply_map = maps:put(SeqNum, ?REPLY_MSG(?COMMAND_ID_QUERY_SM, FromPid, Async, [MessageId]), ReplyMap),
                pending_req_queue = NewPendingReqQueue,
                pending_requests_timeout_timer = schedule_pending_request_timeout(NewPendingReqQueue, PendingReqTimeoutTimer)
            },
            case Async of
                true ->
                    {reply, ok, NewState};
                _ ->
                    {noreply, NewState}
            end
    end;
handle_call(Request, _From, #state{id = Id} = State) ->
    ?WARNING_MSG("connection_id: ~p unknown call request: ~p", [Id, Request]),
    {reply, ok, State}.

handle_cast(Request, State = #state{id = Id}) ->
    ?WARNING_MSG("connection_id: ~p unknown cast request: ~p", [Id, Request]),
    {noreply, State}.

handle_info({SocketType, Socket, Data}, #state{id = Id, transport = Transport} = State) when SocketType == tcp orelse SocketType == ssl ->
    ok = Transport:setopts(Socket, [{active,once}]),
    case process_incoming_data(State, Data) of
        {ok, NewState} ->
            {noreply, NewState};
        Error ->
            ?ERROR_MSG("connection_id: ~p process_incoming_data failed with ~p", [Id, Error]),
            {stop, Error, State}
    end;
handle_info({SocketClosedTag, Sock}, #state{id = Id, socket = Sock} = State) when ?IS_SOCKET_CLOSED_TAG(SocketClosedTag) ->
    ?WARNING_MSG("connection_id: ~p socket closed. reconnect ...", [Id]),
    case reconnect(State) of
        {ok, NewState} ->
            {noreply, NewState};
        Error ->
            {stop, Error, State}
    end;
handle_info({SocketErrorTag, _, Reason}, #state{id = Id} = State) when ?IS_SOCKET_ERROR_TAG(SocketErrorTag) ->
    ?WARNING_MSG("connection_id: ~p socket error: ~p. reconnect ...", [Id, Reason]),
    case reconnect(State) of
        {ok, NewState} ->
            {noreply, NewState};
        Error ->
            {stop, Error, State}
    end;
handle_info(pending_request_timeout_check, State) ->
    {noreply, check_requests_timeout(esmpplib_time:now_msec(), State)};
handle_info(send_enquire_link, #state{transport = Transport, socket = Socket, seq_num = SeqNum, options = Options} = State) ->
    send_command(Transport, Socket, {?COMMAND_ID_ENQUIRE_LINK, ?ESME_ROK, SeqNum, []}),
    {noreply, State#state{enquire_link_timer = schedule_enquire_link(Options), seq_num = get_next_sequence_number(SeqNum)}};
handle_info(start_connection, #state{id = Id, transport = Transport, seq_num = SeqNr, options = Options} = State) ->
    case connect_and_bind(Id, Transport, SeqNr, Options) of
        {ok, Socket, NewSq} ->
            ok = Transport:setopts(Socket, [{active,once}]),
            {noreply, State#state{
                seq_num = NewSq,
                socket = Socket,
                parser = esmpplib_stream_parser:new(maps:get(max_smpp_packet_size, Options)),
                binding_timer = schedule_binding_timeout_check(Options)
            }};
        _Error ->
            case reconnect(State) of
                {ok, NewState} ->
                    {noreply, NewState};
                Error ->
                    {stop, Error, State}
            end
    end;
handle_info(binding_timeout, #state{id = Id} = State) ->
    ?ERROR_MSG("connection_id: ~p binding timeout. reconnect ...", [Id]),
    case reconnect(State) of
        {ok, NewState} ->
            {noreply, NewState};
        Error ->
            {stop, Error, State}
    end;
handle_info(Info, #state{id = Id} = State) ->
    ?WARNING_MSG("connection_id: ~p unknown info message: ~p", [Id, Info]),
    {noreply, State}.

terminate(Reason, #state{id = Id, transport = Transport, socket = Socket, reply_map = ReplyMap, options = Options}) ->
    ?INFO_MSG("connection_id: ~p terminate with reason: ~p", [Id, Reason]),
    close_socket(Transport, Socket),
    cleanup_reply_map(ReplyMap, {error, shutdown_connection}, Options),
    ok.

code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

% internals

process_incoming_data(#state{id = Id, parser = Parser} = State, Data) ->
    case esmpplib_stream_parser:parse(Parser, Data) of
        {ok, {CmdId, _Status, SeqNum, Body} = Pdu, NewParser} ->
            {ok, NewState} = case CmdId of
                ?COMMAND_ID_SUBMIT_SM_RESP ->
                    handle_submit_sm_response(Pdu, State);
                ?COMMAND_ID_DELIVER_SM ->
                    handle_deliver_sm_request(Pdu, State);
                ?COMMAND_ID_QUERY_SM_RESP ->
                    handle_query_sm_response(Pdu, State);
                ?COMMAND_ID_ENQUIRE_LINK ->
                    handle_enquire_link_request(Pdu, State);
                ?COMMAND_ID_ENQUIRE_LINK_RESP ->
                    {ok, State};
                BindCmd when ?IS_BIND_RESPONSE(BindCmd) ->
                    handle_binding_response(Pdu, State);
                ?COMMAND_ID_UNBIND ->
                    #state{transport = Transport, socket = Socket} = State,
                    send_command(Transport, Socket, {?COMMAND_ID_UNBIND_RESP, ?ESME_ROK, SeqNum, []}),
                    reconnect(State);
                ?COMMAND_ID_UNBIND_RESP ->
                    {ok, State};
                ?COMMAND_ID_GENERIC_NACK ->
                    {ok, State};
                _ ->
                    ?WARNING_MSG("connection_id: ~p received unknown message: ~p", [Id, Pdu]),
                    #state{transport = Transport, socket = Socket} = State,
                    send_command(Transport, Socket, {?COMMAND_ID_GENERIC_NACK, ?ESME_RINVCMDID, SeqNum, Body}),
                    {ok, State}
            end,

            case NewState#state.socket of
                undefined ->
                    {ok, NewState};
                _ ->
                    process_incoming_data(NewState#state{parser = NewParser}, <<>>)
            end;
        {more, NewParser} ->
            {ok, State#state{parser = NewParser}};
        {error, CmdId, Status, SeqNum} = P ->
            ?ERROR_MSG("connection_id: ~p invalid pdu packet: ~p. reconnect ...", [Id, P]),
            #state{transport = Transport, socket = Socket} = State,
            case Status of
                S when S == ?ESME_RINVCMDID orelse S == ?ESME_RINVCMDLEN ->
                    send_command(Transport, Socket, {?COMMAND_ID_GENERIC_NACK, Status, SeqNum, []});
                _ ->
                    send_command(Transport, Socket, {?MAKE_RESPONSE(CmdId), Status, SeqNum, []})
            end,
            reconnect(State);
        {error, packet_size_exceeded} ->
            ?ERROR_MSG("connection_id: ~p system_id: ~p packet size exceeded. reconnect ...", [Id]),
            reconnect(State);
        CrashError ->
            ?ERROR_MSG("connection_id: ~p system_id: ~p failed to parse stream with: ~p", [Id, CrashError]),
            reconnect(State)
    end.

handle_binding_response({CmdId, Status, _SeqNum, _Body}, #state{id = Id, options = Options, binding_timer = BindingTimer} = State) ->
    erlang:cancel_timer(BindingTimer),

    case Status of
        ?ESME_ROK ->
            BindingMode = cmd_resp_to_binding_mode(CmdId),
            ?INFO_MSG("connection_id: ~p binding completed -> mode: ~p", [Id, BindingMode]),

            {ok, State#state {
                binding_mode = BindingMode,
                enquire_link_timer = schedule_enquire_link(Options),
                binding_timer = undefined,
                reconnect_attempts = 0
            }};
        _ ->
            ?ERROR_MSG("connection_id: ~p failed to bind with error: (~p) ~p", [Id, Status, smpp_status2bin(Status)]),
            reconnect(State)
    end.

handle_enquire_link_request({CmdId, Status, SeqNum, _Body}, #state{id = Id, transport = Transport, socket = Socket, binding_mode = BindingMode} = State) ->
    case BindingMode of
        undefined ->
            ?WARNING_MSG("connection_id: ~p received ENQUIRE_LINK in outbound state ...", [Id]),
            {ok, State};
        _ ->
            send_command(Transport, Socket, {?MAKE_RESPONSE(CmdId), Status, SeqNum, []}),
            {ok, State}
    end.

handle_submit_sm_response({_CmdId, Status, SeqNum, Body}, #state{reply_map = ReplyMap, pending_req_queue = PendingReqQueue, options = Options} = State) ->
    case maps:take(SeqNum, ReplyMap) of
        {{?COMMAND_ID_SUBMIT_SM, FromPid, Async, [MessageRef, TotalParts]}, NewReplyMap} ->
            case Status of
                ?ESME_ROK ->
                    MessageId = esmpplib_utils:lookup(message_id, Body),
                    case Async of
                        false ->
                            gen_server:reply(FromPid, {ok, MessageId, TotalParts});
                        _ ->
                            run_callback(on_submit_sm_response_successful, 3, [MessageRef, MessageId, TotalParts], Options)
                    end;
                _ ->
                    ErrorMsg = {error, {submit_failed, Status, smpp_status2bin(Status)}},
                    case Async of
                        false ->
                            gen_server:reply(FromPid, ErrorMsg);
                        _ ->
                            run_callback(on_submit_sm_response_failed, 2, [MessageRef, ErrorMsg], Options)
                    end
            end,
            {ok, State#state{reply_map = NewReplyMap, pending_req_queue = esmpplib_pending_request_queue:ack(SeqNum, PendingReqQueue)}};
        _ ->
            {ok, State#state{pending_req_queue = esmpplib_pending_request_queue:ack(SeqNum, PendingReqQueue)}}
    end.

handle_deliver_sm_request({CmdId, Status, SeqNum, Body}, #state{id = Id, options = Options, transport = Transport, socket = Socket} = State) ->
    ?INFO_MSG("connection_id: ~p handle_deliver_sm_request: status: ~p body: ~p", [Id, Status, Body]),

    send_command(Transport, Socket, {?MAKE_RESPONSE(CmdId), Status, SeqNum, []}),

    case Status of
        ?ESME_ROK ->
            Message = esmpplib_utils:lookup(short_message, Body),
            DataCoding = esmpplib_utils:lookup(data_coding, Body),
            SourceAddress = esmpplib_utils:lookup(destination_addr, Body),
            DestinationAddress = esmpplib_utils:lookup(source_addr, Body),

            case re:run(esmpplib_encoding:decode(DataCoding, Message), <<"id:(.*?) sub:(.*?) dlvrd:(.*?) (submit date:|submitdate:)(.*?) (done date:|donedate:)(.*?) stat:(.*?) err:(.*?) text:(.*?)">>, [{capture, all_but_first, binary}]) of
                {match, [MessageId, _Submitted0, _Delivered0, _, SubmitDate0, _, DlrDate0, DlrStatus, ErrorCode0, _Text]} ->
                    SubmitDate = dlr_datetime2ts(SubmitDate0),
                    DoneDate = dlr_datetime2ts(DlrDate0),
                    ErrorCode = esmpplib_utils:safe_bin2int({Id, <<"err">>}, ErrorCode0, 0),
                    run_callback(on_delivery_report, 7, [MessageId, SourceAddress, DestinationAddress, SubmitDate, DoneDate, DlrStatus, ErrorCode], Options);
                _ ->
                    case esmpplib_utils:lookup(receipted_message_id, Body) of
                        undefined ->
                            ?ERROR_MSG("connection_id: ~p handle_deliver_sm_request failed to parse: ~p and receipted_message_id is missing.", [Id, Message]);
                        MessageId ->
                            DlrStatus = esmpplib_msg_status:to_string(esmpplib_utils:lookup(message_state, Body, ?MESSAGE_STATE_UNKNOWN)),
                            ErrorCode = case esmpplib_utils:lookup(network_error_code, Body) of
                                #network_error_code{error = Code} ->
                                    Code;
                                _ ->
                                    0
                            end,
                            run_callback(on_delivery_report, 7, [MessageId, SourceAddress, DestinationAddress, null, null, DlrStatus, ErrorCode], Options)
                    end
            end,
            {ok, State};
        _ ->
            ?ERROR_MSG("connection_id: ~p handle_deliver_sm_request failed status: ~p", [Id, {Status, smpp_status2bin(Status), SeqNum, Body}]),
            {ok, State}
    end.

handle_query_sm_response({_CmdId, Status, SeqNum, Body}, #state{reply_map = ReplyMap, options = Options, pending_req_queue = PendingRqQueue} = State) ->
    case maps:take(SeqNum, ReplyMap) of
        {{?COMMAND_ID_QUERY_SM, FromPid, Async, [MessageId]}, NewReplyMap} ->
            case Status of
                ?ESME_ROK ->
                    Response = [
                        {message_id, esmpplib_utils:lookup(message_id, Body)},
                        {message_state, esmpplib_msg_status:to_string(esmpplib_utils:lookup(message_state, Body))},
                        {final_date, dlr_datetime2ts(esmpplib_utils:lookup(final_date, Body))},
                        {error_code, esmpplib_utils:lookup(error_code, Body)}
                    ],

                    case Async of
                        false ->
                            gen_server:reply(FromPid, {ok, Response});
                        _ ->
                            run_callback(on_query_sm_response, 3, [MessageId, true, Response], Options)
                    end;
                _ ->
                    ErrorMsg = {error, {query_failed, Status, smpp_status2bin(Status)}},
                    case Async of
                        false ->
                            gen_server:reply(FromPid, ErrorMsg);
                        _ ->
                            run_callback(on_query_sm_response, 2, [MessageId, false, ErrorMsg], Options)
                    end
            end,
            {ok, State#state{reply_map = NewReplyMap, pending_req_queue = esmpplib_pending_request_queue:ack(SeqNum, PendingRqQueue)}};
        _ ->
            {ok, State#state{pending_req_queue = esmpplib_pending_request_queue:ack(SeqNum, PendingRqQueue)}}
    end.

connect_and_bind(Id, Transport, SeqNum, Options) ->
    Host = maps:get(host, Options),
    Port = maps:get(port, Options),
    ConnectionTimeout = maps:get(connection_timeout, Options),
    case Transport:connect(Host, Port, ?SOCKET_DEFAULT_OPTIONS, ConnectionTimeout) of
        {ok, Socket} ->
            ?LOG_INFO("connection_id: ~p connection completed: ~p", [Id, Socket]),
            case bind(Transport, Socket, SeqNum, Options) of
                ok ->
                    {ok, Socket, get_next_sequence_number(SeqNum)};
                Error ->
                    ?LOG_ERROR("connection_id: ~p failed to send bind with error: ~p", [Id, Error]),
                    Error
            end;
        Error ->
            ?LOG_ERROR("connection_id: ~p failed to connect with error: ~p", [Id, Error]),
            Error
    end.

bind(Transport, Socket, SeqNum, Options) ->
    CmdId = case maps:get(bind_mode, Options, transceiver) of
        transmitter ->
            ?COMMAND_ID_BIND_TRANSMITTER;
        receiver ->
            ?COMMAND_ID_BIND_RECEIVER;
        transceiver ->
            ?COMMAND_ID_BIND_TRANSCEIVER
    end,

    CmdOptions = [
        {system_id, maps:get(system_id, Options)},
        {password, maps:get(password, Options)},
        {system_type, maps:get(system_type, Options)},
        {interface_version, interface_version(maps:get(interface_version, Options))},
        {addr_ton, maps:get(addr_ton, Options)},
        {addr_npi, maps:get(addr_npi, Options)}
    ],

    send_command(Transport, Socket, {CmdId, ?ESME_ROK, SeqNum, CmdOptions}).

reconnect(#state{
    transport = Transport,
    socket = Socket,
    reply_map = ReplyMap,
    options = Options,
    reconnect_attempts = Attempts,
    enquire_link_timer = EqLinkTimer,
    pending_requests_timeout_timer = PendingReqTimeoutRef } = State) ->

    close_socket(Transport, Socket),
    cancel_timer(EqLinkTimer),
    cancel_timer(PendingReqTimeoutRef),
    cleanup_reply_map(ReplyMap, {error, connection_lost}, Options),

    schedule_reconnect(Attempts, Options),
    NewState = cleanup_state(State),
    {ok, NewState#state{reconnect_attempts = Attempts+1}}.

cleanup_state(#state{id = Id, transport = Transport, options = Options, reconnect_attempts = Rc}) ->
    #state{id = Id, transport = Transport, options = Options, reconnect_attempts = Rc}.

cleanup_reply_map(ReplyMap, Reason, Options) ->
    lists:foreach(fun({_, Msg}) -> failure_reply_to_message(Msg, Reason, Options) end, maps:to_list(ReplyMap)).

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    erlang:cancel_timer(Ref).

close_socket(_Transport, undefined) ->
    ok;
close_socket(Transport, Socket) ->
    Transport:close(Socket).

schedule_reconnect(Attempts, Options) ->
    SendAfter = erlang:min(Attempts*200, maps:get(max_reconnection_time, Options)),
    erlang:send_after(SendAfter, self(), start_connection).

schedule_enquire_link(Options) ->
    case maps:get(enquire_link_time_ms, Options) of
        0 ->
            undefined;
        TimeMs ->
            erlang:send_after(TimeMs, self(), send_enquire_link)
    end.

schedule_binding_timeout_check(Options) ->
    case maps:get(binding_response_timeout, Options) of
        0 ->
            undefined;
        TimeMs ->
            erlang:send_after(TimeMs, self(), binding_timeout)
    end.

schedule_pending_request_timeout(PendingRqQueue, PendingTimerRef) ->
    case PendingTimerRef of
        undefined ->
            case esmpplib_pending_request_queue:peek_next_expired_ack(PendingRqQueue) of
                {ok, _, ExpireTimeMs} ->
                    erlang:send_after(erlang:max(0, ExpireTimeMs - esmpplib_time:now_msec()), self(), pending_request_timeout_check);
                _ ->
                    undefined
            end;
        _ ->
            PendingTimerRef
    end.

check_requests_timeout(Now, #state{options = Options, pending_req_queue = PendingRqQueue, reply_map = ReplyMap} = State) ->
    case esmpplib_pending_request_queue:peek_next_expired_ack(PendingRqQueue) of
        {ok, SeqNum, ExpireTimeMs} ->
            Elapsed = ExpireTimeMs - Now,
            case Elapsed =< 0 of
                true ->
                    ?INFO_MSG("found expired request -> seq_num: ~p", [SeqNum]),
                    NewReplyMap = case maps:take(SeqNum, ReplyMap) of
                        {Msg, NewReplyMap0} ->
                            failure_reply_to_message(Msg, {error, expired}, Options),
                            NewReplyMap0;
                        _ ->
                            ReplyMap
                    end,
                    {ok, _, NewPendingRqQueue} = esmpplib_pending_request_queue:pop_next_expired_ack(PendingRqQueue),
                    check_requests_timeout(Now, State#state{pending_req_queue = NewPendingRqQueue, reply_map = NewReplyMap});
                _ ->
                    ?INFO_MSG("schedule next timeout requests check after: ~p ms", [Elapsed]),
                    TimerRef = erlang:send_after(erlang:max(0, Elapsed), self(), pending_request_timeout_check),
                    State#state{pending_requests_timeout_timer = TimerRef}
            end;
        _ ->
            %?INFO_MSG("no timeout requests to check ...", []),
            State#state{pending_requests_timeout_timer = undefined}
    end.

send_command(Transport, Socket, Cmd) ->
    {ok, RespBin} = smpp_operation:pack(Cmd),
    Transport:send(Socket, RespBin).

failure_reply_to_message({CommandId, FromPid, Async, Args}, Reason, Options) ->
    case Async of
        false ->
            gen_server:reply(FromPid, Reason);
        _ ->
            case CommandId of
                ?COMMAND_ID_SUBMIT_SM ->
                    [MessageRef, _TotalParts] = Args,
                    run_callback(on_submit_sm_response_failed, 2, [MessageRef, Reason], Options);
                ?COMMAND_ID_QUERY_SM ->
                    [MessageId] = Args,
                    run_callback(on_query_sm_response, 3, [MessageId, false, Reason], Options);
                _ ->
                    ok
            end
    end.

default_options() -> #{
    transport => tcp,
    max_smpp_packet_size => 200000, % 200KB,
    connection_timeout => 5000,
    binding_response_timeout => 5000,
    pending_requests_timeout => 10000,
    max_reconnection_time => 5000,
    bind_mode => transceiver,
    system_type => <<"">>,
    interface_version => <<"5.0">>,
    addr_ton => undefined,
    addr_npi => undefined,
    enquire_link_time_ms => 20000,

    service_type => <<"">>,
    data_coding => ?ENCODING_SCHEME_MC_SPECIFIC,
    callback_module => undefined,
    registered_delivery => ?REGISTERED_DELIVERY_MC_ALWAYS
}.

submit_sm_options(SrcAddr, DstAddr, Message, RefNumber, Options) ->
    case esmpplib_encoding:get_data_coding(Message, maps:get(data_coding, Options)) of
        {ok, DataCoding, MaxLength} ->
            case esmpplib_encoding:encode(DataCoding, Message) of
                {ok, EncodedMessage} ->
                    EncodedMessageLength = byte_size(EncodedMessage),

                    SrcAddrType = get_address_type(SrcAddr),
                    DstAddrType = get_address_type(DstAddr),
                    RegisteredDelivery = maps:get(registered_delivery, Options),

                    case EncodedMessageLength =< MaxLength of
                        true ->
                            {ok, submit_sm_options(SrcAddr, SrcAddrType, DstAddr, DstAddrType, ?ESM_CLASS_GSM_NO_FEATURES, DataCoding, EncodedMessageLength, EncodedMessage, RegisteredDelivery, Options)};
                        _ ->
                            % we send the parts in the reversed order and ask for dlr (if requested) only on the first part (last sent).
                            % this way we know the message is properly delivered when first part confirmation arrived.
                            {ok, TotalParts, [FirstPart|OtherParts]} = esmpplib_encoding:split_in_parts(RefNumber, EncodedMessage, MaxLength),
                            FirstPartEncoded = submit_sm_options(SrcAddr, SrcAddrType, DstAddr, DstAddrType, ?ESM_CLASS_GSM_UDHI, DataCoding, byte_size(FirstPart), FirstPart, RegisteredDelivery, Options),
                            EncodedPartsReversed = lists:foldl(fun(Chunk, Acc) -> [submit_sm_options(SrcAddr, SrcAddrType, DstAddr, DstAddrType, ?ESM_CLASS_GSM_UDHI, DataCoding, byte_size(Chunk), Chunk, ?REGISTERED_DELIVERY_MC_NEVER, Options) | Acc] end, [FirstPartEncoded], OtherParts),
                            {ok, TotalParts, EncodedPartsReversed}
                    end;
                _ ->
                    {error, {encoding_failed, DataCoding, Message}}
            end;
        Error ->
            Error
    end.

submit_sm_options(SrcAddr, SrcAddrType, DstAddr, DstAddrType, EsmClass, DataCoding, MsgLength, Msg, RegisteredDelivery, Options) -> [
    {service_type, maps:get(service_type, Options)},
    {registered_delivery, RegisteredDelivery},
    {source_addr_ton, get_ton(SrcAddr, SrcAddrType)},
    {source_addr_npi, get_npi(SrcAddr, SrcAddrType)},
    {source_addr, SrcAddr},
    {dest_addr_ton, get_ton(DstAddr, DstAddrType)},
    {dest_addr_npi, get_npi(DstAddr, DstAddrType)},
    {destination_addr, DstAddr},
    {esm_class, EsmClass},
    {data_coding, DataCoding},
    {sm_length, MsgLength},
    {short_message, Msg}
].

dlr_datetime2ts(<<"00", _/binary>>) ->
    null;
dlr_datetime2ts(<<YY0:2/binary, MM0:2/binary, DD0:2/binary, Hh0:2/binary, Mm0:2/binary>>) ->
    YY = 2000 + binary_to_integer(YY0),
    MM = binary_to_integer(MM0),
    DD = binary_to_integer(DD0),
    Hh = binary_to_integer(Hh0),
    Mm = binary_to_integer(Mm0),
    esmpplib_time:datetime2ts({{YY, MM, DD}, {Hh, Mm, 0}});
dlr_datetime2ts(<<YY0:2/binary, MM0:2/binary, DD0:2/binary, Hh0:2/binary, Mm0:2/binary, Ss0:2/binary>>) ->
    YY = 2000 + binary_to_integer(YY0),
    MM = binary_to_integer(MM0),
    DD = binary_to_integer(DD0),
    Hh = binary_to_integer(Hh0),
    Mm = binary_to_integer(Mm0),
    Ss = binary_to_integer(Ss0),
    esmpplib_time:datetime2ts({{YY, MM, DD}, {Hh, Mm, Ss}});
dlr_datetime2ts(<<YY0:2/binary, MM0:2/binary, DD0:2/binary, Hh0:2/binary, Mm0:2/binary, Ss0:2/binary, _:1/binary, Nn:2/binary, P:1/binary>>) ->
    % 4.7.23.4 Absolute Time Format
    % YYMMDDhhmmsstnnp
    YY = 2000 + binary_to_integer(YY0),
    MM = binary_to_integer(MM0),
    DD = binary_to_integer(DD0),
    Hh = binary_to_integer(Hh0),
    Mm = binary_to_integer(Mm0),
    Ss = binary_to_integer(Ss0),
    Diff = binary_to_integer(Nn)*15*60,
    Ts = esmpplib_time:datetime2ts({{YY, MM, DD}, {Hh, Mm, Ss}}),

    case P of
        <<"+">> ->
            Ts - Diff;
        <<"-">> ->
            Ts + Diff
    end;
dlr_datetime2ts(_) ->
    null.

interface_version(<<"5.0">>) ->
    ?SMPP_VERSION_5_0;
interface_version(<<"3.4">>) ->
    ?SMPP_VERSION_3_4;
interface_version(<<"3.3">>) ->
    ?SMPP_VERSION_3_3;
interface_version(_) ->
    ?ERROR_MSG("unknown interface version. Switch to 3.3", []),
    ?SMPP_VERSION_3_3.

cmd_resp_to_binding_mode(?COMMAND_ID_BIND_TRANSMITTER_RESP) ->
    transmitter;
cmd_resp_to_binding_mode(?COMMAND_ID_BIND_RECEIVER_RESP) ->
    receiver;
cmd_resp_to_binding_mode(?COMMAND_ID_BIND_TRANSCEIVER_RESP) ->
    transceiver.

get_transport(tcp) ->
    ranch_tcp;
get_transport(ssl) ->
    ranch_ssl.

get_ton(Address, AddressType) ->
    case AddressType of
        alpha ->
            ?TON_ALPHANUMERIC;
        digit ->
            case byte_size(Address) of
                Int when Int > 8 andalso Int < 16 ->
                    ?TON_INTERNATIONAL;
                Ns when Ns > 2 andalso Ns < 9 ->
                    ?TON_NETWORK_SPECIFIC;
                _ ->
                    ?TON_UNKNOWN
            end
    end.

get_npi(Address, AddressType) ->
    AddressLength = byte_size(Address),
    case AddressType == digit andalso AddressLength> 8 andalso AddressLength < 16 of
        true ->
            ?NPI_ISDN;
        _ ->
            ?NPI_UNKNOWN
    end.

get_address_type(Number) ->
    get_address_type([N || <<N:1/binary>> <= Number], digit).
get_address_type([], digit) ->
    digit;
get_address_type([Char | Rest], _Any) ->
    case binary:decode_unsigned(Char) of
        Val when Val =:= 43 orelse Val > 47 andalso Val < 58 ->
            get_address_type(Rest, digit);
        _Val ->
            alpha
    end.

get_next_ref_num(R) ->
    case R of
        255 ->
            1;
        _ ->
            R+1
    end.

get_next_sequence_number(Nr) ->
    case Nr of
        ?SMPP_SEQ_NUM_MAX ->
            1;
        _ ->
            Nr + 1
    end.

run_callback(Method, Arity, Args, Options) ->
    case maps:get(callback_module, Options) of
        undefined ->
            ok;
        Handler ->
            case erlang:function_exported(Handler, Method, Arity) of
                true ->
                    catch erlang:apply(Handler, Method, Args),
                    ok;
                _ ->
                    ok
            end
    end.

smpp_status2bin(Status) ->
    {_, StatusStr, _} = smpp:err(Status),
    StatusStr.