%%%-------------------------------------------------------------------
%%%
%%% riak_kv_qry_worker: Riak SQL per-query workers
%%%
%%% Copyright (C) 2015 Basho Technologies, Inc. All rights reserved
%%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%%
%%%-------------------------------------------------------------------

%% @doc Under the queue manager accepting raw parsed and lexed queries
%%      from the user, workers take individual queries and communicate
%%      with eleveldb backend to execute the queries (with
%%      sub-queries), and hold the results until fetched back to the
%%      user.

-module(riak_kv_qry_worker).

-behaviour(gen_server).

%% OTP API
-export([start_link/1]).

%% gen_server callbacks
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-include_lib("riak_ql/include/riak_ql_ddl.hrl").

-define(NO_SIDEEFFECTS, []).
-define(NO_MAX_RESULTS, no_max_results).
-define(NO_PG_SORT, undefined).

-record(state, {
          name                                :: atom(),
          qry           = none                :: none | #riak_sql_v1{},
          qid           = undefined           :: undefined | {node(), non_neg_integer()},
          sub_qrys      = []                  :: [integer()],
          status        = void                :: void | accumulating_chunks,
          receiver_pid                        :: pid(),
          result        = []                  :: [{non_neg_integer(), list()}] | [{binary(), term()}],
          run_sub_qs_fn = fun run_sub_qs_fn/1 :: fun()
         }).

%%%===================================================================
%%% OTP API
%%%===================================================================
-spec start_link(RegisteredName::atom()) -> {ok, pid()} | ignore | {error, term()}.
start_link(RegisteredName) ->
    gen_server:start_link({local, RegisteredName}, ?MODULE, [RegisteredName], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init([RegisteredName::atom()]) -> {ok, #state{}}.
%% @private
init([RegisteredName]) ->
    pop_next_query(),
    {ok, new_state(RegisteredName)}.

handle_call(_, _, State) ->
    {reply, {error, not_handled}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
%% @private
handle_cast(Msg, State) ->
    lager:info("Not handling cast message ~p", [Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(pop_next_query, State1) ->
    {query, ReceiverPid, QId, Query, DDL} = riak_kv_qry_queue:blocking_pop(),
    {ok, State2} = execute_query(ReceiverPid, QId, Query, State1),
    {noreply, State2};
handle_info({{SubQId, QId}, done}, #state{ qid = QId } = State) ->
    {noreply, subqueries_done(SubQId, QId, State)};
handle_info({{SubQId, QId}, {results, Chunk}}, #state{ qid = QId } = State) ->
    {noreply, add_subquery_result(SubQId, Chunk, State)};
handle_info({{SubQId, QId}, {error, Reason} = Error},
            State = #state{receiver_pid = ReceiverPid,
                           qid    = QId,
                           result = IndexedChunks}) ->
    lager:warning("Error ~p while collecting on QId ~p (~p);"
                  " dropping ~b chunks of data accumulated so far",
                  [Reason, QId, SubQId, length(IndexedChunks)]),
    ReceiverPid ! Error,
    pop_next_query(),
    {noreply, new_state(State#state.name)};

handle_info({{_SubQId, QId1}, _}, State = #state{qid = QId2}) when QId1 =/= QId2 ->
    %% catches late results or errors such getting results for invalid QIds.
    lager:debug("Bad query id ~p (expected ~p)", [QId1, QId2]),
    {noreply, State}.

-spec terminate(term(), #state{}) -> term().
%% @private
terminate(_Reason, _State) ->
    ok.

-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec new_state(RegisteredName::atom()) -> #state{}.
new_state(RegisteredName) ->
    #state{name = RegisteredName}.

run_sub_qs_fn([]) -> ok;
run_sub_qs_fn([{{qry, Q}, {qid, QId}} | T]) ->
    Table = Q#riak_sql_v1.'FROM',
    Bucket = riak_kv_pb_timeseries:table_to_bucket(Table),
    %% fix these up too
    Timeout = {timeout, 10000},
    Me = self(),
    CoverageFn = {colocated, riak_kv_qry_coverage_plan},
    Opts = [Bucket, none, Q, Timeout, all, undefined, CoverageFn],
    {ok, _PID} = riak_kv_index_fsm_sup:start_index_fsm(node(), [{raw, QId, Me}, Opts]),
    run_sub_qs_fn(T).

decode_results(KVList, SelectSpec) ->
    lists:append(
      [extract_riak_object(SelectSpec, V) || {_, V} <- KVList]).

extract_riak_object(SelectSpec, V) when is_binary(V) ->
    % don't care about bkey
    RObj = riak_object:from_binary(<<>>, <<>>, V),
    case riak_object:get_value(RObj) of
        <<>> ->
            %% record was deleted
            [];
        FullRecord ->
            filter_columns(lists:flatten(SelectSpec), FullRecord)
    end.

%% Pull out the values we're interested in based on the select,
%% statement, e.g. select user, geoloc returns only user and geoloc columns.
-spec filter_columns(SelectSpec::[binary()],
                     ColValues::[{Field::binary(), Value::binary()}]) ->
        ColValues2::[{Field::binary(), Value::binary()}].
filter_columns([<<"*">>], ColValues) ->
    ColValues;
filter_columns(SelectSpec, ColValues) ->
    [Col || {Field, _} = Col <- ColValues, lists:member(Field, SelectSpec)].

%% Send a message to this process to get the next query.
pop_next_query() ->
    self() ! pop_next_query.

%% 
execute_query(ReceiverPid, QId, [Qry|_] = SubQueries,
              #state{ run_sub_qs_fn = RunSubQs } = State) ->
    Indices = lists:seq(1, length(SubQueries)),
    ZQueries = lists:zip(Indices, SubQueries),
    SubQs = [{{qry, Q}, {qid, {I, QId}}} || {I, Q} <- ZQueries],
    ok = RunSubQs(SubQs),
    {ok, State#state{qid          = QId,
                     receiver_pid = ReceiverPid,
                     qry          = Qry,
                     sub_qrys     = Indices}}.

%%
add_subquery_result(SubQId, Chunk, 
                    #state{qry      = Qry,
                           result   = IndexedChunks,
                           sub_qrys = SubQs} = State) ->
    #riak_sql_v1{'SELECT' = SelectSpec} = Qry,
    case lists:member(SubQId, SubQs) of
        true ->
            Decoded = decode_results(lists:flatten(Chunk), SelectSpec),
            NSubQ = lists:delete(SubQId, SubQs),
            State#state{status   = accumulating_chunks,
                        result   = [{SubQId, Decoded} | IndexedChunks],
                        sub_qrys = NSubQ};
        false ->
            %% discard; Don't touch state as it may have already 'finished'.
            State
    end.

subqueries_done(SubQId, QId,
                #state{qid          = QId,
                       receiver_pid = ReceiverPid,
                       result       = IndexedChunks,
                       sub_qrys     = SubQQ} = State) ->
    case SubQQ of
        [] ->
            lager:debug("Done collecting on QId ~p (~p): ~p", [QId, SubQId, IndexedChunks]),
            %% sort by index, to reassemble according to coverage plan
            {_, R2} = lists:unzip(lists:sort(IndexedChunks)),
            Results = lists:append(R2),
            %   send the results to the waiting client process
            ReceiverPid ! {ok, Results},
            pop_next_query(),
            %% drop indexes, serialize
            new_state(State#state.name);
        _MoreSubQueriesNotDone ->
            State
    end.

%%%===================================================================
%%% Unit tests
%%%===================================================================
-ifdef(TEST).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").


-endif.
