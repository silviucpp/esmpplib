-module(esmpplib_stream_parser).

-include("esmpplib.hrl").

-export([
    new/1,
    parse/2
]).

-record(state, {
    buffer = <<>>,
    max_packet_bytes
}).

new(MaxPacketBytes) ->
    #state{max_packet_bytes = MaxPacketBytes}.

parse(#state{buffer = Buffer, max_packet_bytes = MaxPacketBytes} = State, Data0) ->
    Data = append_buffer(Buffer, Data0),

    case Data of
        <<CmdLen:32, Rest/binary>> ->
            Len = CmdLen - 4,

            case MaxPacketBytes =/= null andalso Len > MaxPacketBytes of
                true ->
                    {error, packet_size_exceeded};
                _ ->
                    case Rest of
                        <<PduRest:Len/binary-unit:8, NextPdus/binary>> ->
                            BinPdu = <<CmdLen:32, PduRest/binary>>,
                            case catch smpp_operation:unpack(BinPdu) of
                                {ok, Pdu} ->
                                    {ok, Pdu, State#state{buffer = NextPdus}};
                                {'EXIT', Reason} ->
                                    {error, Reason};
                                PduFormatError ->
                                    PduFormatError
                            end;
                        _ ->
                            {more, State#state{buffer = Data}}
                    end
            end;
        _ ->
            {more, State#state{buffer = Data}}
    end.

% internals

append_buffer(<<>>, Chunk) ->
    Chunk;
append_buffer(Buffer, Chunk) ->
    <<Buffer/binary, Chunk/binary>>.
