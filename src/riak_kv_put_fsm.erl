%% -------------------------------------------------------------------
%%
%% riak_put_fsm: coordination of Riak PUT requests
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc coordination of Riak PUT requests

-module(riak_kv_put_fsm).
%-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
%-endif.
-include_lib("riak_kv_vnode.hrl").
-include_lib("riak_kv_js_pools.hrl").
-include("riak_kv_wm_raw.hrl").

-behaviour(gen_fsm).
-define(DEFAULT_OPTS, [{returnbody, false}, {update_last_modified, true}]).
-export([start/6,start/7,start/8,pure_start/9]).
-export([init/1, handle_event/3, handle_sync_event/4,
         handle_info/3, terminate/3, code_change/4]).
-export([initialize/2,waiting_vnode_w/2,waiting_vnode_dw/2]).

-define(PURE_DRIVER, gen_fsm_test_driver).
-export([pure_t0/0]).

-record(state, {robj :: riak_object:riak_object(),
                client :: {pid(), reference()},
                rclient :: riak_client:riak_client(),
                n :: pos_integer(),
                w :: pos_integer(),
                dw :: non_neg_integer(),
                preflist :: [{pos_integer(), atom()}],
                bkey :: {riak_object:bucket(), riak_object:key()},
                waiting_for :: list(),
                req_id :: pos_integer(),
                starttime :: pos_integer(),
                replied_w :: list(),
                replied_dw :: list(),
                replied_fail :: list(),
                timeout :: pos_integer(),
                tref    :: reference(),
                ring :: riak_core_ring:riak_core_ring(),
                startnow :: {pos_integer(), pos_integer(), pos_integer()},
                vnode_options :: list(),
                returnbody :: boolean(),
                resobjs :: list(),
                allowmult :: boolean(),
                update_last_modified :: boolean(),
                pure_p :: boolean(),
                pure_opts :: list()
               }).

%% Inventory of impure actions:
%%  x riak_core_ring_manager:get_my_ring().
%%  x riak_core_bucket:get_bucket()
%%  x Client !
%%  x timer:send_after()
%%  x riak_core_util:moment()
%%  x riak_core_util:chash_key()
%%  x riak_core_node_watcher:nodes()
%%  x riak_kv_util:try_cast()
%%  x riak_kv_stat:update()
%%  x riak_kv_js_manager:blocking_dispatch()
%%  x spawn()
%%
%% Impure functions that we know that we use but don't
%% care about:
%%  * now()

start(ReqId,RObj,W,DW,Timeout,From) ->
    start(ReqId,RObj,W,DW,Timeout,From,[]).

start(ReqId,RObj,W,DW,Timeout,From,Options) ->
    start(ReqId,RObj,W,DW,Timeout,From,Options,[]).

start(ReqId,RObj,W,DW,Timeout,From,Options,PureOpts) ->
    gen_fsm:start(?MODULE, {ReqId,RObj,W,DW,Timeout,From,Options,PureOpts}, []).

pure_start(FsmID, ReqId,RObj,W,DW,Timeout,From,Options,PureOpts) ->
    ?PURE_DRIVER:start(FsmID, ?MODULE, {ReqId,RObj,W,DW,Timeout,From,Options,PureOpts}).

%% @private
init({ReqId,RObj0,W0,DW0,Timeout,Client,Options0,PureOpts}) ->
    Options = flatten_options(proplists:unfold(Options0 ++ ?DEFAULT_OPTS), []),
    PureP = proplists:get_value(debug, PureOpts, false),
    StateData0 = #state{pure_p = PureP, pure_opts = PureOpts},
    {ok, Ring} = impure_get_my_ring(StateData0),
    BucketProps = impure_get_bucket(StateData0,riak_object:bucket(RObj0),Ring),
    N = proplists:get_value(n_val,BucketProps),
    W = riak_kv_util:expand_rw_value(w, W0, BucketProps, N),

    %% Expand the DW value, but also ensure that DW <= W
    DW = erlang:min(riak_kv_util:expand_rw_value(dw, DW0, BucketProps, N), W),

    case (W > N) or (DW > N) of
        true ->
            impure_bang(StateData0, Client,
                        {ReqId, {error, {n_val_violation, N}}}),
            {stop, normal, none};
        false ->
            AllowMult = proplists:get_value(allow_mult,BucketProps),
            {ok, RClient} = riak:local_client(),
            Bucket = riak_object:bucket(RObj0),
            Key = riak_object:key(RObj0),
            StateData1 = StateData0#state{robj=RObj0, 
                                client=Client, w=W, dw=DW, bkey={Bucket, Key},
                                req_id=ReqId, timeout=Timeout, ring=Ring,
                                rclient=RClient, 
                                vnode_options=[],
                                resobjs=[], allowmult=AllowMult},
            StateData2 = handle_options(Options, StateData1),
            {ok,initialize,StateData2,0}
    end.

%%
%% Given an expanded proplist of options, take the first entry for any given key
%% and ignore the rest
%%
%% @private
flatten_options([], Opts) ->
    Opts;
flatten_options([{Key, Value} | Rest], Opts) ->
    case lists:keymember(Key, 1, Opts) of
        true ->
            flatten_options(Rest, Opts);
        false ->
            flatten_options(Rest, [{Key, Value} | Opts])
    end.

%% @private
handle_options([], State) ->
    State;
handle_options([{update_last_modified, Value}|T], State) ->
    handle_options(T, State#state{update_last_modified=Value});
handle_options([{returnbody, true}|T], State) ->
    VnodeOpts = [{returnbody, true} | State#state.vnode_options],
    %% Force DW>0 if requesting return body to ensure the dw event 
    %% returned by the vnode includes the object.
    handle_options(T, State#state{vnode_options=VnodeOpts,
                                  dw=erlang:max(1,State#state.dw),
                                  returnbody=true});
handle_options([{returnbody, false}|T], State) ->
    case has_postcommit_hooks(element(1,State#state.bkey), State) of
        true ->
            %% We have post-commit hooks, we'll need to get the body back
            %% from the vnode, even though we don't plan to return that to the
            %% original caller.  Force DW>0 to ensure the dw event returned by
            %% the vnode includes the object.
            VnodeOpts = [{returnbody, true} | State#state.vnode_options],
            handle_options(T, State#state{vnode_options=VnodeOpts,
                                          dw=erlang:max(1,State#state.dw),
                                          returnbody=false});
        false ->
            handle_options(T, State#state{returnbody=false})
    end;
handle_options([{_,_}|T], State) -> handle_options(T, State).

%% @private
initialize(timeout, StateData0=#state{robj=RObj0, req_id=ReqId, client=Client,
                                      update_last_modified=UpdateLastMod,
                                      timeout=Timeout, ring=Ring, bkey={Bucket,Key}=BKey,
                                      rclient=RClient, vnode_options=VnodeOptions}) ->
    case invoke_hook(precommit, RClient, update_last_modified(UpdateLastMod, RObj0), StateData0) of
        fail ->
            impure_bang(StateData0, Client, {ReqId, {error, precommit_fail}}),
            {stop, normal, StateData0};
        {fail, Reason} ->
            impure_bang(StateData0, Client,
                        {ReqId, {error, {precommit_fail, Reason}}}),
            {stop, normal, StateData0};
        RObj1 ->
            StartNow = now(),
            TRef = impure_timer_send_after(StateData0, Timeout),
            RealStartTime = impure_riak_core_util_moment(StateData0),
            BucketProps = impure_get_bucket(StateData0, Bucket, Ring),
            DocIdx = impure_riak_core_util_chash_key(StateData0, {Bucket, Key}),
            Req = ?KV_PUT_REQ{
              bkey = BKey,
              object = RObj1,
              req_id = ReqId,
              start_time = RealStartTime,
              options = VnodeOptions},
            N = proplists:get_value(n_val,BucketProps),
            Preflist = riak_core_ring:preflist(DocIdx, Ring),
            %% TODO: Replace this with call to riak_kv_vnode:put/6
            {Targets, Fallbacks} = lists:split(N, Preflist),
            UpNodes = impure_riak_core_node_watcher_nodes(StateData0),
            {Sent1, Pangs1} = impure_riak_kv_util_try_cast(
                                StateData0, Req, UpNodes, Targets),
            Sent = case length(Sent1) =:= N of   % Sent is [{Index,TargetNode,SentNode}]
                       true -> Sent1;
                       false -> Sent1 ++ riak_kv_util:fallback(Req,UpNodes,Pangs1,Fallbacks)
                   end,
            StateData = StateData0#state{
                          robj=RObj1, n=N, preflist=Preflist,
                          waiting_for=Sent, starttime=riak_core_util:moment(),
                          replied_w=[], replied_dw=[], replied_fail=[],
                          tref=TRef,startnow=StartNow},
            {next_state,waiting_vnode_w,StateData}
    end.

waiting_vnode_w({w, Idx, ReqId},
                StateData=#state{w=W,dw=DW,req_id=ReqId,client=Client,replied_w=Replied0}) ->
    Replied = [Idx|Replied0],
    case length(Replied) >= W of
        true ->
            case DW of
                0 ->
                    impure_bang(StateData, Client, {ReqId, ok}),
                    update_stats(StateData),
                    {stop,normal,StateData};
                _ ->
                    NewStateData = StateData#state{replied_w=Replied},
                    {next_state,waiting_vnode_dw,NewStateData}
            end;
        false ->
            NewStateData = StateData#state{replied_w=Replied},
            {next_state,waiting_vnode_w,NewStateData}
    end;
waiting_vnode_w({dw, Idx, _ReqId},
                  StateData=#state{replied_dw=Replied0}) ->
    Replied = [Idx|Replied0],
    NewStateData = StateData#state{replied_dw=Replied},
    {next_state,waiting_vnode_w,NewStateData};
waiting_vnode_w({dw, Idx, ResObj, _ReqId},
                  StateData=#state{replied_dw=Replied0, resobjs=ResObjs0}) ->
    Replied = [Idx|Replied0],
    ResObjs = [ResObj|ResObjs0],
    NewStateData = StateData#state{replied_dw=Replied, resobjs=ResObjs},
    {next_state,waiting_vnode_w,NewStateData};
waiting_vnode_w({fail, Idx, ReqId},
                  StateData=#state{n=N,w=W,client=Client,
                                   replied_fail=Replied0}) ->
    Replied = [Idx|Replied0],
    NewStateData = StateData#state{replied_fail=Replied},
    case (N - length(Replied)) >= W of
        true ->
            {next_state,waiting_vnode_w,NewStateData};
        false ->
            update_stats(StateData),
            impure_bang(NewStateData, Client, {ReqId, {error,too_many_fails}}),
            {stop,normal,NewStateData}
    end;
waiting_vnode_w(timeout, StateData=#state{client=Client,req_id=ReqId}) ->
    update_stats(StateData),
    impure_bang(StateData, Client, {ReqId, {error,timeout}}),
    {stop,normal,StateData}.

waiting_vnode_dw({w, _Idx, ReqId},
          StateData=#state{req_id=ReqId}) ->
    {next_state,waiting_vnode_dw,StateData};
waiting_vnode_dw({dw, Idx, ReqId},
                 StateData=#state{dw=DW, client=Client, replied_dw=Replied0}) ->
    Replied = [Idx|Replied0],
    case length(Replied) >= DW of
        true ->
            impure_bang(StateData, Client, {ReqId, ok}),
            update_stats(StateData),
            {stop,normal,StateData};
        false ->
            NewStateData = StateData#state{replied_dw=Replied},
            {next_state,waiting_vnode_dw,NewStateData}
    end;
waiting_vnode_dw({dw, Idx, ResObj, ReqId},
                 StateData=#state{dw=DW, client=Client, replied_dw=Replied0,
                                  allowmult=AllowMult, returnbody=ReturnBody,
                                  rclient=RClient, resobjs=ResObjs0}) ->
    Replied = [Idx|Replied0],
    ResObjs = [ResObj|ResObjs0],
    case length(Replied) >= DW of
        true ->
            ReplyObj = merge_robjs(ResObjs, AllowMult),
            Reply = case ReturnBody of
                        true  -> {ok, ReplyObj};
                        false -> ok
                    end,
            impure_bang(StateData, Client, {ReqId, Reply}),
            invoke_hook(postcommit, RClient, ReplyObj, StateData),
            update_stats(StateData),
            {stop,normal,StateData};
        false ->
            NewStateData = StateData#state{replied_dw=Replied,resobjs=ResObjs},
            {next_state,waiting_vnode_dw,NewStateData}
    end;
waiting_vnode_dw({fail, Idx, ReqId},
                  StateData=#state{n=N,dw=DW,client=Client,
                                   replied_fail=Replied0}) ->
    Replied = [Idx|Replied0],
    NewStateData = StateData#state{replied_fail=Replied},
    case (N - length(Replied)) >= DW of
        true ->
            {next_state,waiting_vnode_dw,NewStateData};
        false ->
            impure_bang(NewStateData, Client, {ReqId, {error,too_many_fails}}),
            {stop,normal,NewStateData}
    end;
waiting_vnode_dw(timeout, StateData=#state{client=Client,req_id=ReqId}) ->
    update_stats(StateData),
    impure_bang(StateData, Client, {ReqId, {error,timeout}}),
    {stop,normal,StateData}.

%% @private
handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

%% @private
handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

%% @private

handle_info(timeout, StateName, StateData) ->
    ?MODULE:StateName(timeout, StateData);
handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

%% @private
terminate(Reason, _StateName, _State) ->
    Reason.

%% @private
code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

%%
%% Update X-Riak-VTag and X-Riak-Last-Modified in the object's metadata, if
%% necessary.
%%
%% @private
update_last_modified(false, RObj) ->
    RObj;
update_last_modified(true, RObj) ->
    MD0 = case dict:find(clean, riak_object:get_update_metadata(RObj)) of
              {ok, true} ->
                  %% There have been no changes to updatemetadata. If we stash the
                  %% last modified in this dict, it will cause us to lose existing
                  %% metadata (bz://508). If there is only one instance of metadata,
                  %% we can safely update that one, but in the case of multiple siblings,
                  %% it's hard to know which one to use. In that situation, use the update
                  %% metadata as is.
                  case riak_object:get_metadatas(RObj) of
                      [MD] ->
                          MD;
                      _ ->
                          riak_object:get_update_metadata(RObj)
                  end;
               _ ->
                  riak_object:get_update_metadata(RObj)
          end,
    NewMD = dict:store(?MD_VTAG, make_vtag(RObj),
                       dict:store(?MD_LASTMOD, erlang:now(),
                                  MD0)),
    riak_object:apply_updates(riak_object:update_metadata(RObj, NewMD)).

make_vtag(RObj) ->
    <<HashAsNum:128/integer>> = crypto:md5(term_to_binary(riak_object:vclock(RObj))),
    riak_core_util:integer_to_list(HashAsNum,62).

update_stats(#state{startnow=StartNow} = StateData) ->
    EndNow = now(),
    impure_riak_kv_stat_update(StateData, {put_fsm_time, timer:now_diff(EndNow, StartNow)}).

%% Internal functions
invoke_hook(HookType, RClient, RObj, StateData) ->
    Bucket = riak_object:bucket(RObj),
    BucketProps = impure_get_rclient_bucket(
                    StateData, RClient, Bucket, StateData#state.ring),
    R = proplists:get_value(HookType, BucketProps, []),
    case R of
        <<"none">> ->
            RObj;
        [] ->
            RObj;
        Hooks when is_list(Hooks) ->
            run_hooks(HookType, RObj, Hooks, StateData)
    end.

run_hooks(_HookType, RObj, [], _StateData) ->
    RObj;
run_hooks(HookType, RObj, [{struct, Hook}|T], StateData) ->
    Mod = proplists:get_value(<<"mod">>, Hook),
    Fun = proplists:get_value(<<"fun">>, Hook),
    JSName = proplists:get_value(<<"name">>, Hook),
    Result = invoke_hook(HookType, Mod, Fun, JSName, RObj, StateData),
    case HookType of
        precommit ->
            case Result of
                fail ->
                    Result;
                _ ->
                    run_hooks(HookType, Result, T, StateData)
            end;
        postcommit ->
            run_hooks(HookType, RObj, T, StateData)
    end.


invoke_hook(precommit, Mod0, Fun0, undefined, RObj, _StateData) ->
    Mod = binary_to_atom(Mod0, utf8),
    Fun = binary_to_atom(Fun0, utf8),
    wrap_hook(Mod, Fun, RObj);
invoke_hook(precommit, undefined, undefined, JSName, RObj, StateData) ->
    case impure_riak_kv_js_manager_blocking_dispatch(StateData, ?JSPOOL_HOOK, {{jsfun, JSName}, RObj}, 5) of
        {ok, <<"fail">>} ->
            fail;
        {ok, [{<<"fail">>, Message}]} ->
            {fail, Message};
        {ok, NewObj} ->
            riak_object:from_json(NewObj);
        {error, Error} ->
            error_logger:error_msg("Error executing pre-commit hook: ~s",
                                   [Error]),
            fail
    end;
invoke_hook(postcommit, Mod0, Fun0, undefined, Obj, #state{pure_p = PureP}) ->
    Mod = binary_to_atom(Mod0, utf8),
    Fun = binary_to_atom(Fun0, utf8),
    F = fun() -> wrap_hook(Mod, Fun, Obj) end,
    if PureP -> F();
       true  -> proc_lib:spawn(F)
    end;
invoke_hook(postcommit, undefined, undefined, _JSName, _Obj, _StateData) ->
    error_logger:warning_msg("Javascript post-commit hooks aren't implemented");
%% NOP to handle all other cases
invoke_hook(_, _, _, _, RObj, _StateData) ->
    RObj.

wrap_hook(Mod, Fun, Obj)->
    try Mod:Fun(Obj)
    catch
        EType:X ->
            error_logger:error_msg("problem invoking hook ~p:~p -> ~p:~p~n~p~n",
                                   [Mod,Fun,EType,X,erlang:get_stacktrace()]),
            fail
    end.

merge_robjs(RObjs0,AllowMult) ->
    RObjs1 = [X || X <- RObjs0,
                   X /= undefined],
    case RObjs1 of
        [] -> {error, notfound};
        _ -> riak_object:reconcile(RObjs1,AllowMult)
    end.

has_postcommit_hooks(Bucket, StateData) ->
    lists:flatten(proplists:get_all_values(postcommit, impure_get_bucket(StateData, Bucket, StateData#state.ring))) /= [].

%% Impure handling stuff

impure_get_my_ring(StateData) ->
    riak_kv_get_fsm:imp_get_my_ring(
      StateData#state.pure_p, StateData#state.pure_opts).

impure_get_bucket(StateData, Bucket, Ring) ->
    riak_kv_get_fsm:imp_get_bucket(
      StateData#state.pure_p, StateData#state.pure_opts, Bucket, Ring).

impure_get_rclient_bucket(#state{pure_p = false}, RClient, Bucket, _Ring) ->
    RClient:get_bucket(Bucket);
impure_get_rclient_bucket(StateData, _RClient, Bucket, Ring) ->
    riak_kv_get_fsm:imp_get_bucket(
      StateData#state.pure_p, StateData#state.pure_opts, Bucket, Ring).

impure_bang(StateData, Client, Msg) ->
    riak_kv_get_fsm:imp_bang(
      StateData#state.pure_p, StateData#state.pure_opts, Client, Msg).

impure_timer_send_after(StateData, Timeout) ->
    riak_kv_get_fsm:imp_timer_send_after(
      StateData#state.pure_p, StateData#state.pure_opts, Timeout).

impure_riak_core_util_moment(StateData) ->
    riak_kv_get_fsm:imp_riak_core_util_moment(
      StateData#state.pure_p, StateData#state.pure_opts).

impure_riak_core_util_chash_key(StateData, BKey) ->
    riak_kv_get_fsm:imp_riak_core_util_chash_key(
      StateData#state.pure_p, StateData#state.pure_opts, BKey).

impure_riak_core_node_watcher_nodes(StateData) ->
    riak_kv_get_fsm:imp_riak_core_node_watcher_nodes(
      StateData#state.pure_p, StateData#state.pure_opts).

impure_riak_kv_util_try_cast(StateData, Req, UpNodes, Targets) ->
    riak_kv_get_fsm:imp_riak_kv_util_try_cast(
      StateData#state.pure_p, StateData#state.pure_opts, Req, UpNodes, Targets).

impure_riak_kv_stat_update(StateData, Name) ->
    riak_kv_get_fsm:imp_riak_kv_stat_update(StateData#state.pure_p, StateData#state.pure_opts, Name).

impure_riak_kv_js_manager_blocking_dispatch(#state{pure_p = false}, Hook, Thingie, Int) ->
    riak_kv_js_manager:blocking_dispatch(Hook, Thingie, Int);
impure_riak_kv_js_manager_blocking_dispatch(#state{pure_opts = Pure_Opts}, Hook, Thingie, Int) ->
    Default = {error, "Default not supported by pure interface"},
    riak_kv_get_fsm:impure_interp(
      proplists:get_value(js_manager_reply, Pure_Opts, Default),
      {Hook, Thingie, Int}).
    
%%%%%%%%%%

pure_t0() ->
    todo.

-ifdef(TEST).

make_vtag_test() ->
    Obj = riak_object:new(<<"b">>,<<"k">>,<<"v1">>),
    ?assertNot(make_vtag(Obj) =:=
               make_vtag(riak_object:increment_vclock(Obj,<<"client_id">>))).

-endif. % TEST
