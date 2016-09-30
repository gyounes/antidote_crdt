%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
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
%%
%% -------------------------------------------------------------------

-module(crdt_properties).

-define(PROPER_NO_TRANS, true).
-include_lib("proper/include/proper.hrl").



-export([crdt_satisfies_spec/3, clock_le/2]).

-export_type([clocked_operation/0]).



-type clock() :: #{replica() => non_neg_integer()}.
-type clocked_operation() :: {Clock :: clock(), Operation :: any()}.
-type clocked_effect() :: {Clock :: clock(), Effect :: any()}.
-type replica() :: dc1 | dc2 | dc3.

-record(test_replica_state, {
  state :: any(),
  clock = #{} :: clock(),
  operations = [] :: [clocked_operation()],
  downstreamOps = [] :: [clocked_effect()]
}).

-type test_replica_state() :: #test_replica_state{}.
-type test_state() :: #{replica() => test_replica_state()}.
-type test_operation() :: {pull, replica(), replica()} | {exec, replica(), any()}.


%% this checks whether the implementation satisfies a given CRDT specification
%% Crdt: module name of the CRDT to test
%% OperationGen: proper generator for generating a single random CRDT operation
%% Spec: A function which takes a list of {Clock,Operation} pairs. The clock can be used to determine the happens-before relation between operations
-spec crdt_satisfies_spec(atom(), fun(() -> proper_types:raw_type()), fun(([clocked_operation()]) -> boolean())) -> proper:forall_clause().
crdt_satisfies_spec(Crdt, OperationGen, Spec) ->
  ?FORALL(Ops, generateOps(OperationGen),
      checkSpec(Crdt, Ops, Spec)
    ).



% generates a list of operations
generateOps(OpGen) ->
  list(oneof([
    % pulls one operation from the first replica to the second
    {pull, replica(), replica()},
    % execute operation on a given replica
    {exec, replica(), OpGen()}
  ])).

replica() -> oneof([dc1, dc2, dc3]).

clock_le(A, B) ->
  lists:all(fun(R) -> maps:get(R, A) =< maps:get(R, B, 0) end, maps:keys(A)).


% executes/checks the specification
checkSpec(Crdt, Ops, Spec) ->
  InitialState = maps:from_list(
    [{Dc, #test_replica_state{state = Crdt:new()}} || Dc <- [dc1, dc2, dc3]]),
  EndState = execSystem(Crdt, Ops, InitialState),
  lists:all(fun(R) -> checkSpecEnd(Crdt, Spec, EndState, R) end, maps:keys(EndState)).

checkSpecEnd(Crdt, Spec, EndState, R) ->
  RState = maps:get(R, EndState),
  RClock = RState#test_replica_state.clock,
  RValue = Crdt:value(RState#test_replica_state.state),

  % get the visible operations:
  VisibleOperations = [{Clock, Op} ||
    Replica <- maps:keys(EndState),
    {Clock, Op} <- (maps:get(Replica, EndState))#test_replica_state.operations,
    clock_le(Clock, RClock)],

  SpecValue = Spec(VisibleOperations),
  SpecValue == RValue.


-spec execSystem(atom(), [test_operation()], test_state()) -> test_state().
execSystem(_Crdt, [], State) ->
  State;
execSystem(Crdt, [{pull, Source, Target}|RemainingOps], State) ->
  TargetState = maps:get(Target, State),
  TargetClock = TargetState#test_replica_state.clock,
  SourceState = maps:get(Source, State),
  % get all downstream operations at the source, which are not yet delivered to the target,
  % and which have all dependencies already delivered at the target
  Effects = [{Clock, Effect} ||
    {Clock, Effect} <- SourceState#test_replica_state.downstreamOps,
    not clock_le(Clock, TargetClock),
    clock_le(Clock#{Source => 0}, TargetClock)
  ],
  NewState =
    case Effects of
      [] -> State;
      [{Clock, Op}|_] ->
        {ok, NewCrdtState} = Crdt:update(Op, TargetState#test_replica_state.state),
        NewTargetState = TargetState#test_replica_state{
          state = NewCrdtState,
          clock = TargetClock#{Source => maps:get(Source, Clock)}
        },
        State#{Target => NewTargetState}
    end,


  execSystem(Crdt, RemainingOps, NewState);
execSystem(Crdt, [{exec, Replica, Op}|RemainingOps], State) ->
  ReplicaState = maps:get(Replica, State),
  CrdtState = ReplicaState#test_replica_state.state,
  {ok, Effect} = Crdt:downstream(Op, CrdtState),
  {ok, NewCrdtState} = Crdt:update(Effect, CrdtState),

  ReplicaClock = ReplicaState#test_replica_state.clock,
  NewReplicaClock = ReplicaClock#{Replica => maps:get(Replica, ReplicaClock, 0) + 1},

  NewReplicaState = ReplicaState#test_replica_state{
    state = NewCrdtState,
    clock = NewReplicaClock,
    operations = ReplicaState#test_replica_state.operations ++ [{NewReplicaClock, Op}],
    downstreamOps = ReplicaState#test_replica_state.downstreamOps ++ [{NewReplicaClock, Effect}]
  },
  NewState = State#{Replica => NewReplicaState},
  execSystem(Crdt, RemainingOps, NewState).
