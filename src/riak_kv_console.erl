%% -------------------------------------------------------------------
%%
%% riak_console: interface for Riak admin commands
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

%% @doc interface for Riak admin commands

-module(riak_kv_console).

-export([join/1,
         staged_join/1,
         leave/1,
         remove/1,
         status/1,
         vnode_status/1,
         reip/1,
         reip_manual/1,
         ringready/1,
         cluster_info/1,
         down/1,
         aae_status/1,
         repair_2i/1,
         reformat_indexes/1,
         reformat_objects/1,
         reload_code/1,
         bucket_type_status/1,
         bucket_type_activate/1,
         bucket_type_create/1,
         bucket_type_update/1,
         bucket_type_reset/1,
         bucket_type_list/1,
         tictacaae_cmd/1
        ]).

-export([ensemble_status/1]).

%% Reused by Yokozuna for printing AAE status.
-export([aae_exchange_status/1,
         aae_repair_status/1,
         aae_tree_status/1]).

-include_lib("kernel/include/logger.hrl").

join([NodeStr]) ->
    join(NodeStr, fun riak_core:join/1,
         "Sent join request to ~s~n", [NodeStr]).

staged_join([NodeStr]) ->
    Node = list_to_atom(NodeStr),
    join(NodeStr, fun riak_core:staged_join/1,
         "Success: staged join request for ~p to ~p~n", [node(), Node]).

join(NodeStr, JoinFn, SuccessFmt, SuccessArgs) ->
    try
        case JoinFn(NodeStr) of
            ok ->
                io:format(SuccessFmt, SuccessArgs),
                ok;
            {error, not_reachable} ->
                io:format("Node ~s is not reachable!~n", [NodeStr]),
                error;
            {error, different_ring_sizes} ->
                io:format("Failed: ~s has a different ring_creation_size~n",
                          [NodeStr]),
                error;
            {error, unable_to_get_join_ring} ->
                io:format("Failed: Unable to get ring from ~s~n", [NodeStr]),
                error;
            {error, not_single_node} ->
                io:format("Failed: This node is already a member of a "
                          "cluster~n"),
                error;
            {error, self_join} ->
                io:format("Failed: This node cannot join itself in a "
                          "cluster~n"),
                error;
            {error, _} ->
                io:format("Join failed. Try again in a few moments.~n", []),
                error
        end
    catch
        Exception:Reason ->
            ?LOG_ERROR("Join failed ~p:~p", [Exception, Reason]),
            io:format("Join failed, see log for details~n"),
            error
    end.


leave([]) ->
    try
        case riak_core:leave() of
            ok ->
                io:format("Success: ~p will shutdown after handing off "
                          "its data~n", [node()]),
                ok;
            {error, already_leaving} ->
                io:format("~p is already in the process of leaving the "
                          "cluster.~n", [node()]),
                ok;
            {error, not_member} ->
                io:format("Failed: ~p is not a member of the cluster.~n",
                          [node()]),
                error;
            {error, only_member} ->
                io:format("Failed: ~p is the only member.~n", [node()]),
                error
        end
    catch
        Exception:Reason ->
            ?LOG_ERROR("Leave failed ~p:~p", [Exception, Reason]),
            io:format("Leave failed, see log for details~n"),
            error
    end.

remove([Node]) ->
    try
        case riak_core:remove(list_to_atom(Node)) of
            ok ->
                io:format("Success: ~p removed from the cluster~n", [Node]),
                ok;
            {error, not_member} ->
                io:format("Failed: ~p is not a member of the cluster.~n",
                          [Node]),
                error;
            {error, only_member} ->
                io:format("Failed: ~p is the only member.~n", [Node]),
                error
        end
    catch
        Exception:Reason ->
            ?LOG_ERROR("Remove failed ~p:~p", [Exception, Reason]),
            io:format("Remove failed, see log for details~n"),
            error
    end.

down([Node]) ->
    try
        case riak_core:down(list_to_atom(Node)) of
            ok ->
                io:format("Success: ~p marked as down~n", [Node]),
                ok;
            {error, is_up} ->
                io:format("Failed: ~s is up~n", [Node]),
                error;
            {error, not_member} ->
                io:format("Failed: ~p is not a member of the cluster.~n",
                          [Node]),
                error;
            {error, only_member} ->
                io:format("Failed: ~p is the only member.~n", [Node]),
                error
        end
    catch
        Exception:Reason ->
            ?LOG_ERROR("Down failed ~p:~p", [Exception, Reason]),
            io:format("Down failed, see log for details~n"),
            error
    end.

-spec(status([]) -> ok).
status([]) ->
    try
        Stats = riak_kv_status:statistics(),
	StatString = format_stats(Stats,
                    ["-------------------------------------------\n",
		     io_lib:format("1-minute stats for ~p~n",[node()])]),
	io:format("~s\n", [StatString])
    catch
        Exception:Reason ->
            ?LOG_ERROR("Status failed ~p:~p", [Exception,
                    Reason]),
            io:format("Status failed, see log for details~n"),
            error
    end.

-spec(vnode_status([]) -> ok).
vnode_status([]) ->
    try
        case riak_kv_status:vnode_status() of
            [] ->
                io:format("There are no active vnodes.~n");
            Statuses ->
                io:format("~s~n-------------------------------------------~n~n",
                          ["Vnode status information"]),
                print_vnode_statuses(lists:sort(Statuses))
        end
    catch
        Exception:Reason ->
            ?LOG_ERROR("Backend status failed ~p:~p", [Exception,
                    Reason]),
            io:format("Backend status failed, see log for details~n"),
            error
    end.

reip([OldNode, NewNode]) ->
    try
        %% reip is called when node is down (so riak_core_ring_manager is not running),
        %% so it has to use the basic ring operations.
        %%
        %% Do *not* convert to use riak_core_ring_manager:ring_trans.
        %%
        case application:load(riak_core) of
            %% a process, such as cuttlefish, may have already loaded riak_core
            {error,{already_loaded,riak_core}} -> ok;
            ok -> ok
        end,
        RingStateDir = app_helper:get_env(riak_core, ring_state_dir),
        {ok, RingFile} = riak_core_ring_manager:find_latest_ringfile(),
        BackupFN = filename:join([RingStateDir, filename:basename(RingFile)++".BAK"]),
        {ok, _} = file:copy(RingFile, BackupFN),
        io:format("Backed up existing ring file to ~p~n", [BackupFN]),
        Ring = riak_core_ring_manager:read_ringfile(RingFile),
        NewRing = riak_core_ring:rename_node(Ring, OldNode, NewNode),
        ok = riak_core_ring_manager:do_write_ringfile(NewRing),
        io:format("New ring file written to ~p~n",
            [element(2, riak_core_ring_manager:find_latest_ringfile())])
    catch
        Exception:Reason ->
            io:format("Reip failed ~p:~p", [Exception, Reason]),
            error
    end.

reip_manual([OldNode, NewNode, Dir, ClusterName]) ->
    try
        %% reip/1 requires riak_core to be loaded to learn the Ring Directory
        %% and the Cluster Name.  In reip_manual/1 these can be passed in 
        %% instead
        RingDir = atom_to_list(Dir),
        Cluster = atom_to_list(ClusterName),
        {ok, RingFile} =
            riak_core_ring_manager:find_latest_ringfile(RingDir, Cluster),
        io:format("~nCHANGE DETAILS:~n"),
        io:format("RingFile to update ~p~n", [RingFile]),
        BackupFN =
            filename:join([RingDir, filename:basename(RingFile)++".BAK"]),
        {ok, _} = file:copy(RingFile, BackupFN),
        io:format("Backed up existing ring file to ~p~n", [BackupFN]),
        Ring = riak_core_ring_manager:read_ringfile(RingFile),
        NewRing = riak_core_ring:rename_node(Ring, OldNode, NewNode),
        NewRingFN =
            riak_core_ring_manager:generate_ring_filename(
                RingDir, Cluster),
        ok = riak_core_ring_manager:do_write_ringfile(NewRing, NewRingFN),
        io:format("New ring file written to ~p~n", [NewRingFN]),
        io:format("~nATTENTION REQUIRED:~n"),
        io:format(
            "Update required to riak.conf nodename before restarting node;"
            ++ " nodename should be changed to ~s~n",
            [atom_to_list(NewNode)]),
        io:format("~nok~n")
    catch
        Exception:Reason ->
            io:format("Reip failed ~p:~p", [Exception, Reason]),
            error
    end.

%% Check if all nodes in the cluster agree on the partition assignment
-spec(ringready([]) -> ok | error).
ringready([]) ->
    try
        case riak_core_status:ringready() of
            {ok, Nodes} ->
                io:format("TRUE All nodes agree on the ring ~p\n", [Nodes]);
            {error, {different_owners, N1, N2}} ->
                io:format("FALSE Node ~p and ~p list different partition owners\n", [N1, N2]),
                error;
            {error, {nodes_down, Down}} ->
                io:format("FALSE ~p down.  All nodes need to be up to check.\n", [Down]),
                error
        end
    catch
        Exception:Reason ->
            ?LOG_ERROR("Ringready failed ~p:~p", [Exception,
                    Reason]),
            io:format("Ringready failed, see log for details~n"),
            error
    end.

cluster_info([OutFile|Rest]) ->
    try
        case lists:reverse(atomify_nodestrs(Rest)) of
            [] ->
                cluster_info:dump_all_connected(OutFile);
            Nodes ->
                cluster_info:dump_nodes(Nodes, OutFile)
        end
    catch
        error:{badmatch, {error, eacces}} ->
            io:format("Cluster_info failed, permission denied writing to ~p~n", [OutFile]);
        error:{badmatch, {error, enoent}} ->
            io:format("Cluster_info failed, no such directory ~p~n", [filename:dirname(OutFile)]);
        error:{badmatch, {error, enotdir}} ->
            io:format("Cluster_info failed, not a directory ~p~n", [filename:dirname(OutFile)]);
        Exception:Reason ->
            ?LOG_ERROR("Cluster_info failed ~p:~p",
                [Exception, Reason]),
            io:format("Cluster_info failed, see log for details~n"),
            error
    end.

reload_code([]) ->
    case app_helper:get_env(riak_kv, add_paths) of
        List when is_list(List) ->
            _ = [ reload_path(filename:absname(Path)) || Path <- List ],
            ok;
        _ -> ok
    end.

reload_path(Path) ->
    {ok, Beams} = file:list_dir(Path),
    [ reload_file(filename:absname(Beam, Path)) || Beam <- Beams, ".beam" == filename:extension(Beam) ].

reload_file(Filename) ->
    Mod = list_to_atom(filename:basename(Filename, ".beam")),
    case code:is_loaded(Mod) of
        {file, Filename} ->
            code:soft_purge(Mod),
            {module, Mod} = code:load_file(Mod),
            io:format("Reloaded module ~w from ~s.~n", [Mod, Filename]);
        {file, Other} ->
            io:format("CONFLICT: Module ~w originally loaded from ~s, won't reload from ~s.~n", [Mod, Other, Filename]);
        _ ->
            io:format("Module ~w not yet loaded, skipped.~n", [Mod])
    end.

aae_status([]) ->
    ExchangeInfo = riak_kv_entropy_info:compute_exchange_info(),
    aae_exchange_status(ExchangeInfo),
    io:format("~n"),
    TreeInfo = riak_kv_entropy_info:compute_tree_info(),
    aae_tree_status(TreeInfo),
    io:format("~n"),
    aae_repair_status(ExchangeInfo).

aae_exchange_status(ExchangeInfo) ->
    io:format("~s~n", [string:centre(" Exchanges ", 79, $=)]),
    io:format("~-49s  ~-12s  ~-12s~n", ["Index", "Last (ago)", "All (ago)"]),
    io:format("~79..-s~n", [""]),
    _ = [begin
         Now = os:timestamp(),
         LastStr = format_timestamp(Now, LastTS),
         AllStr = format_timestamp(Now, AllTS),
         io:format("~-49b  ~-12s  ~-12s~n", [Index, LastStr, AllStr]),
         ok
     end || {Index, LastTS, AllTS, _Repairs} <- ExchangeInfo],
    ok.

aae_repair_status(ExchangeInfo) ->
    io:format("~s~n", [string:centre(" Keys Repaired ", 79, $=)]),
    io:format("~-49s  ~s  ~s  ~s~n", ["Index",
                                      string:centre("Last", 8),
                                      string:centre("Mean", 8),
                                      string:centre("Max", 8)]),
    io:format("~79..-s~n", [""]),
    _ = [begin
         io:format("~-49b  ~s  ~s  ~s~n", [Index,
                                           string:centre(integer_to_list(Last), 8),
                                           string:centre(integer_to_list(Mean), 8),
                                           string:centre(integer_to_list(Max), 8)]),
         ok
     end || {Index, _, _, {Last,_Min,Max,Mean}} <- ExchangeInfo],
    ok.

aae_tree_status(TreeInfo) ->
    io:format("~s~n", [string:centre(" Entropy Trees ", 79, $=)]),
    io:format("~-49s  Built (ago)~n", ["Index"]),
    io:format("~79..-s~n", [""]),
    _ = [begin
         Now = os:timestamp(),
         BuiltStr = format_timestamp(Now, BuiltTS),
         io:format("~-49b  ~s~n", [Index, BuiltStr]),
         ok
     end || {Index, BuiltTS} <- TreeInfo],
    ok.

format_timestamp(_Now, undefined) ->
    "--";
format_timestamp(Now, TS) ->
    riak_core_format:human_time_fmt("~.1f", timer:now_diff(Now, TS)).

parse_int(IntStr) ->
    try
        list_to_integer(IntStr)
    catch
        error:badarg ->
            undefined
    end.

index_reformat_options([], Opts) ->
    Defaults = [{concurrency, 2}, {batch_size, 100}],
    AddIfAbsent =
        fun({Name,Val}, Acc) ->
            case lists:keymember(Name, 1, Acc) of
                true ->
                    Acc;
                false ->
                    [{Name, Val} | Acc]
            end
        end,
    lists:foldl(AddIfAbsent, Opts, Defaults);
index_reformat_options(["--downgrade"], Opts) ->
    [{downgrade, true} | Opts];
index_reformat_options(["--downgrade" | More], _Opts) ->
    io:format("Invalid arguments after downgrade switch : ~p~n", [More]),
    undefined;
index_reformat_options([IntStr | Rest], Opts) ->
    HasConcurrency = lists:keymember(concurrency, 1, Opts),
    HasBatchSize = lists:keymember(batch_size, 1, Opts),
    case {parse_int(IntStr), HasConcurrency, HasBatchSize} of
        {_, true, true} ->
            io:format("Expected --downgrade instead of ~p~n", [IntStr]),
            undefined;
        {undefined, _, _ } ->
            io:format("Expected integer parameter instead of ~p~n", [IntStr]),
            undefined;
        {IntVal, false, false} ->
            index_reformat_options(Rest, [{concurrency, IntVal} | Opts]);
        {IntVal, true, false} ->
            index_reformat_options(Rest, [{batch_size, IntVal} | Opts])
    end;
index_reformat_options(_, _) ->
    undefined.

reformat_indexes(Args) ->
    Opts = index_reformat_options(Args, []),
    case Opts of
        undefined ->
            io:format("Expected options: <concurrency> <batch size> [--downgrade]~n"),
            ok;
        _ ->
            start_reformat(riak_kv_util, fix_incorrect_index_entries, [Opts]),
            io:format("index reformat started with options ~p ~n", [Opts]),
            io:format("check console.log for status information~n"),
            ok
    end.

reformat_objects([KillHandoffsStr]) ->
    reformat_objects([KillHandoffsStr, "2"]);
reformat_objects(["true", ConcurrencyStr | _Rest]) ->
    reformat_objects([true, ConcurrencyStr]);
reformat_objects(["false", ConcurrencyStr | _Rest]) ->
    reformat_objects([false, ConcurrencyStr]);
reformat_objects([KillHandoffs, ConcurrencyStr]) when is_atom(KillHandoffs) ->
    case parse_int(ConcurrencyStr) of
        C when C > 0 ->
            start_reformat(riak_kv_reformat, run,
                           [v0, [{concurrency, C}, {kill_handoffs, KillHandoffs}]]),
            io:format("object reformat started with concurrency ~p~n", [C]),
            io:format("check console.log for status information~n");
        _ ->
            io:format("ERROR: second argument must be an integer greater than zero.~n"),
            error

    end;
reformat_objects(_) ->
    io:format("ERROR: first argument must be either \"true\" or \"false\".~n"),
    error.

start_reformat(M, F, A) ->
    spawn(fun() -> run_reformat(M, F, A) end).

run_reformat(M, F, A) ->
    try erlang:apply(M, F, A)
    catch
        Err:Reason ->
            ?LOG_ERROR("index reformat crashed with error type ~p and reason: ~p",
                        [Err, Reason])
    end.

bucket_type_status([TypeStr]) ->
    Type = unicode:characters_to_binary(TypeStr, utf8, utf8),
    Return = bucket_type_print_status(Type, riak_core_bucket_type:status(Type)),
    bucket_type_print_props(bucket_type_raw_props(Type)),
    Return.


bucket_type_raw_props(<<"default">>) ->
    riak_core_bucket_props:defaults();
bucket_type_raw_props(Type) ->
    riak_core_claimant:get_bucket_type(Type, undefined, false).

bucket_type_print_status(Type, undefined) ->
    io:format("~ts is not an existing bucket type~n", [Type]),
    {error, undefined};
bucket_type_print_status(Type, created) ->
    io:format("~ts has been created but cannot be activated yet~n", [Type]),
    {error, not_ready};
bucket_type_print_status(Type, ready) ->
    io:format("~ts has been created and may be activated~n", [Type]),
    ok;
bucket_type_print_status(Type, active) ->
    io:format("~ts is active~n", [Type]),
    ok.

bucket_type_print_props(undefined) ->
    ok;
bucket_type_print_props(Props) ->
    io:format("~n"),
    [io:format("~p: ~p~n", [K, V]) || {K, V} <- Props].

bucket_type_activate([TypeStr]) ->
    Type = unicode:characters_to_binary(TypeStr, utf8, utf8),
    IsFirst = bucket_type_is_first(),
    bucket_type_print_activate_result(Type, riak_core_bucket_type:activate(Type), IsFirst).

bucket_type_print_activate_result(Type, ok, IsFirst) ->
    io:format("~ts has been activated~n", [Type]),
    case IsFirst of
        true ->
            io:format("~n"),
            io:format("WARNING: Nodes in this cluster can no longer be~n"
                      "downgraded to a version of Riak prior to 2.0~n");
        false ->
            ok
    end;
bucket_type_print_activate_result(Type, {error, undefined}, _IsFirst) ->
    bucket_type_print_status(Type, undefined);
bucket_type_print_activate_result(Type, {error, not_ready}, _IsFirst) ->
    bucket_type_print_status(Type, created).

bucket_type_create([TypeStr]) ->
    bucket_type_create([TypeStr, ""]);
bucket_type_create([TypeStr, ""]) ->
    Type = unicode:characters_to_binary(TypeStr, utf8, utf8),
    EmptyProps = {struct, [{<<"props">>, {struct, []}}]},
    bucket_type_create(Type, EmptyProps);
bucket_type_create([TypeStr, PropsStr]) ->
    Type = unicode:characters_to_binary(TypeStr, utf8, utf8),
    bucket_type_create(Type, catch mochijson2:decode(PropsStr)).

bucket_type_create(Type, {struct, Fields}) ->
    case proplists:get_value(<<"props">>, Fields) of
        {struct, Props} ->
            ErlProps = [riak_kv_wm_utils:erlify_bucket_prop(P) || P <- Props],
            bucket_type_print_create_result(Type, riak_core_bucket_type:create(Type, ErlProps));
        _ ->
            io:format("Cannot create bucket type ~ts: no props field found in json~n", [Type]),
            error
    end;
bucket_type_create(Type, _) ->
    io:format("Cannot create bucket type ~ts: invalid json~n", [Type]),
    error.

bucket_type_print_create_result(Type, ok) ->
    io:format("~ts created~n", [Type]),
    case bucket_type_is_first() of
        true ->
            io:format("~n"),
            io:format("WARNING: After activating ~ts, nodes in this cluster~n"
                      "can no longer be downgraded to a version of Riak "
                      "prior to 2.0~n", [Type]);
        false ->
            ok
    end;
bucket_type_print_create_result(Type, {error, Reason}) ->
    io:format("Error creating bucket type ~ts:~n", [Type]),
    io:format(bucket_error_xlate(Reason)),
    io:format("~n"),
    error.

bucket_type_update([TypeStr, PropsStr]) ->
    Type = unicode:characters_to_binary(TypeStr, utf8, utf8),
    bucket_type_update(Type, catch mochijson2:decode(PropsStr)).

bucket_type_update(Type, {struct, Fields}) ->
    case proplists:get_value(<<"props">>, Fields) of
        {struct, Props} ->
            ErlProps = [riak_kv_wm_utils:erlify_bucket_prop(P) || P <- Props],
            bucket_type_print_update_result(Type, riak_core_bucket_type:update(Type, ErlProps));
        _ ->
            io:format("Cannot create bucket type ~ts: no props field found in json~n", [Type]),
            error
    end;
bucket_type_update(Type, _) ->
    io:format("Cannot update bucket type: ~ts: invalid json~n", [Type]),
    error.

bucket_type_print_update_result(Type, ok) ->
    io:format("~ts updated~n", [Type]);
bucket_type_print_update_result(Type, {error, Reason}) ->
    io:format("Error updating bucket type ~ts:~n", [Type]),
    io:format(bucket_error_xlate(Reason)),
    io:format("~n"),
    error.

bucket_type_reset([TypeStr]) ->
    Type = unicode:characters_to_binary(TypeStr, utf8, utf8),
    bucket_type_print_reset_result(Type, riak_core_bucket_type:reset(Type)).

bucket_type_print_reset_result(Type, ok) ->
    io:format("~ts reset~n", [Type]);
bucket_type_print_reset_result(Type, {error, Reason}) ->
    io:format("Error updating bucket type ~ts: ~p~n", [Type, Reason]),
    error.

bucket_type_list([]) ->
    It = riak_core_bucket_type:iterator(),
    io:format("default (active)~n"),
    bucket_type_print_list(It).

bucket_type_print_list(It) ->
    case riak_core_bucket_type:itr_done(It) of
        true ->
            riak_core_bucket_type:itr_close(It);
        false ->
            {Type, Props} = riak_core_bucket_type:itr_value(It),
            ActiveStr = case proplists:get_value(active, Props, false) of
                            true -> "active";
                            false -> "not active"
                        end,

            io:format("~ts (~s)~n", [Type, ActiveStr]),
            bucket_type_print_list(riak_core_bucket_type:itr_next(It))
    end.

bucket_type_is_first() ->
    It = riak_core_bucket_type:iterator(),
    bucket_type_is_first(It, false).

bucket_type_is_first(It, true) ->
    %% found an active bucket type
    riak_core_bucket_type:itr_close(It),
    false;
bucket_type_is_first(It, false) ->
    case riak_core_bucket_type:itr_done(It) of
        true ->
            %% no active bucket types found
            ok = riak_core_bucket_type:itr_close(It),
            true;
        false ->
            {_, Props} = riak_core_bucket_type:itr_value(It),
            Active = proplists:get_value(active, Props, false),
            bucket_type_is_first(riak_core_bucket_type:itr_next(It), Active)
    end.

repair_2i(["status"]) ->
    try
        Status = riak_kv_2i_aae:get_status(),
        Report = riak_kv_2i_aae:to_report(Status),
        io:format("2i repair status is running:\n~s", [Report]),
        ok
    catch
        exit:{noproc, _NoProcErr} ->
            io:format("2i repair is not running\n", []),
            ok
    end;
repair_2i(["kill"]) ->
    case whereis(riak_kv_2i_aae) of
        Pid when is_pid(Pid) ->
            try
                riak_kv_2i_aae:stop(60000)
            catch
                _:_->
                    ?LOG_WARNING("Asking nicely did not work."
                                  " Will try a hammer"),
                    ok
            end,
            Mon = monitor(process, riak_kv_2i_aae),
            exit(Pid, kill),
            receive
                {'DOWN', Mon, _, _, _} ->
                    ?LOG_INFO("2i repair process has been killed by user"
                               " request"),
                    io:format("The 2i repair process has ceased to be.\n"
                              "Since it was killed forcibly, you may have to "
                              "wait some time\n"
                              "for all internal locks to be released before "
                              "trying again\n", []),
                    ok
            end;
        undefined ->
            io:format("2i repair is not running\n"),
            ok
    end;
repair_2i(Args) ->
    case validate_repair_2i_args(Args) of
        {ok, IdxList, DutyCycle} ->
            case length(IdxList) < 5 of
                true ->
                    io:format("Will repair 2i on these partitions:\n", []),
                    _ = [io:format("\t~p\n", [Idx]) || Idx <- IdxList],
                    ok;
                false ->
                    io:format("Will repair 2i data on ~p partitions\n",
                              [length(IdxList)]),
                    ok
            end,
            Ret = riak_kv_2i_aae:start(IdxList, DutyCycle),
            case Ret of
                {ok, _Pid} ->
                    io:format("Watch the logs for 2i repair progress reports\n", []),
                    ok;
                {error, {lock_failed, not_built}} ->
                    io:format("Error: The AAE tree for that partition has not been built yet\n", []),
                    error;
                {error, {lock_failed, LockErr}} ->
                    io:format("Error: Could not get a lock on AAE tree for"
                              " partition ~p : ~p\n", [hd(IdxList), LockErr]),
                    error;
                {error, already_running} ->
                    io:format("Error: 2i repair is already running. Check the logs for progress\n", []),
                    error;
                {error, early_exit} ->
                    io:format("Error: 2i repair finished immediately. Check the logs for details\n", []),
                    error;
                {error, Reason} ->
                    io:format("Error running 2i repair : ~p\n", [Reason]),
                    error
            end;
        {error, aae_disabled} ->
            io:format("Error: AAE is currently not enabled\n", []),
            error;
        {error, Reason} ->
            io:format("Error: ~p\n", [Reason]),
            io:format("Usage: riak-admin repair-2i [--speed [1-100]] <Idx> ...\n", []),
            io:format("Speed defaults to 100 (full speed)\n", []),
            io:format("If no partitions are given, all partitions in the\n"
                      "node are repaired\n", []),
            error
    end.

ensemble_status([]) ->
    riak_kv_ensemble_console:ensemble_overview();
ensemble_status(["root"]) ->
    riak_kv_ensemble_console:ensemble_detail(root);
ensemble_status([Str]) ->
    N = parse_int(Str),
    case N of
        undefined ->
            io:format("No such ensemble: ~s~n", [Str]);
        _ ->
            riak_kv_ensemble_console:ensemble_detail(N)
    end.


-define(DEFAULT_AAEFOLD_OUTFILE, "aaefold-%o-results-%t.json").

tictacaae_cmd_optspecs() ->
    [
     {node,      $n,        "node",        {string, atom_to_list(node())},  "Node, or all"},
     {partition, $p,        "partition",   {string, "all"},   "Partition, or all"},
     {format,   undefined,  "format",      {string, "table"}, "table or json"},
     {show,     undefined,  "show", {string, "unbuilt,rebuilding,building"}, "tree states to show"},
     {output,    $o,        "output", {string, ?DEFAULT_AAEFOLD_OUTFILE}, "dump results of an aae fold operation to file (\"-\" for stdout)"}
    ].

tictacaae_cmd_ensure_options_consistent(_, all) -> ok;
tictacaae_cmd_ensure_options_consistent(NN, Specific) when length(NN) > 1,
                                                           Specific /= all ->
    io:format("With multiple nodes, only -p=all is acceptable\n", []),
    throw(inconsistent_options);
tictacaae_cmd_ensure_options_consistent(_, _) -> ok.


tictacaae_cmd_usage() ->
    %% getopt:usage/3 will print to stderr, so:
    io:format(
"Usage:
    Set/show rebuild schedule on an AAE controller managing PARTITION on NODE:

        riak admin tictacaae rebuild_schedule [-n NODE] [-p PARTITION] [RW RD]

    Set/show storeheads flag on an AAE controller managing PARTITION on NODE:

        riak admin tictacaae storeheads [-n NODE] [-p PARTITION] [VALUE]

    Set/show tokenbucket flag on a vnode managing PARTITION on NODE:

        riak admin tictacaae tokenbucket [-n NODE] [-p PARTITION] [VALUE]

    Set/show riak_kv tictacaae VAR on NODE:

        riak admin tictacaae VAR [-n NODE] [VAL]

        VAR is one of rebuildtick, exchangetick, maxresults, rangeboost.

    Set/show node worker pool sizes on NODE:

        riak admin tictacaae POOL [-n NODE] [VAL]

        POOL is one of rebuildtreeworkers, rebuildstoreworkers, aaefoldworkers.

    Set next rebuild time to now + DELAY sec, on PARTITION on NODE (default is
    all partitions on local node):

        riak admin tictacaae rebuild-soon [-n NODE] [-p PARTITION] DELAY

    Same as \"rebuild-soon 0\", plus send a rebuild poke:

        riak admin tictacaae rebuild-now [-n NODE] [-p PARTITION] DELAY

    Print the tree rebuild status:

        riak admin tictacaae treestatus [--format table|json] [--show STATES]

        STATES is a comma-separated list of 'unbuilt', 'built',
        'rebuilding', 'building', or 'all'. Default is
        'unbuilt,rebuilding,building'.

    AAE fold operations, dumping results in JSON format to a file specified with '-o'.

    List buckets:

        riak tictacaae fold list-buckets NVAL

    Find keys matching filters:

        riak tictacaae fold find-keys BUCKET KEY_RANGE MODIFIED_RANGE
                                      sibling_count=COUNT|object_size=BYTES

        where BUCKET is BUCKETNAME|TYPENAME/BUCKETNAME,
        KEY_RANGE is all|FROM,TO, MODIFIED_RANGE is all|FROM,TO (in RFC3339 format).

    Count keys matching filters:

        riak tictacaae fold find-keys BUCKET KEY_RANGE MODIFIED_RANGE
                                      sibling_count=COUNT|object_size=BYTES

        Same as above, only return the count of keys.

    Find/count tombstones in the range that match the criteria:

        riak tictacaae fold find|count-tombstones KEY_RANGE SEGMENTS MODIFIED_RANGE

        where KEY_RANGE and MODIFIED_RANGE are as above, and SEGMENTS is
        all|S1,S2,...;TREE_SIZE and TREE_SIZE is xxsmall|xsmall|small|medium|large|xlarge.

    Reap tombstones in the range that match the criteria:

        riak tictacaae fold reap-tombstones KEY_RANGE SEGMENTS MODIFIED_RANGE CHANGE_METHOD

        where KEY_RANGE, MODIFIED_RANGE and SEGMENTS are as above and CHANGE_METHOD is
        jobs=N|local|count.

    Collect object stats in the specified ranges:

        riak tictacaae fold object-stats BUCKET KEY_RANGE MODIFIED_RANGE

        Returns the following:
          - the total count of objects in the key range;
          - the accumulated total size of all objects in the range;
          - a list [{Magnitude, ObjectCount}] tuples where Magnitude represents
            the order of magnitude of the size of the object.

    Erase keys matching filters:

        riak tictacaae fold erase-keys BUCKET KEY_RANGE SEGMENTS MODIFIED_RANGE CHANGE_METHOD

        BUCKET, KEY_RANGE and MODIFIED_RANGE are as above.

    Repair keys matching filters:

        riak tictacaae fold repair-keys BUCKET KEY_RANGE MODIFIED_RANGE

        BUCKET, KEY_RANGE and MODIFIED_RANGE are as above.
").

tictacaae_cmd([Item | Cmdline]) ->
    case application:get_env(riak_kv, tictacaae_active) of
        {ok, active} ->
            try
                {ok, Parsed} = getopt:parse(tictacaae_cmd_optspecs(), Cmdline),
                tictacaae_cmd2(Item, Parsed)
            catch
                error:_e:_st ->
                    io:format("~p / ~p\n\n", [_e, _st]),
                    tictacaae_cmd_usage();
                throw:_ ->
                    tictacaae_cmd_usage()
            end;
        _ ->
            io:format("tictacaae not active\n", [])
    end;
tictacaae_cmd(_) ->
    tictacaae_cmd_usage().

tictacaae_cmd2(Item, {Options, Args}) ->
    Nodes = extract_nodes(Options),
    Partitions = extract_partitions(Options),
    ok = tictacaae_cmd_ensure_options_consistent(Nodes, Partitions),
    PostSetResultF =
        fun(Res, Par, Val) ->
            case Res of
                [{ok, {P, N}}] ->
                    io:format("Set ~s to ~s on partition ~b on ~s\n",
                              [Par, Val, P, N]);
                [{ok, N}] ->
                    io:format("Set ~s to ~s on ~s\n",
                              [Par, Val, N]);
                Multiple ->
                    case length([PN || {Resx, PN} <- Multiple, Resx == ok]) of
                        AllSucceeded when AllSucceeded == length(Multiple) ->
                            io:format("Set ~s to ~s on ~b (v)nodes\n",
                                      [Par, Val, length(Multiple)]);
                        SomeSucceeded when SomeSucceeded > 0 ->
                            io:format("Successfully set ~s to ~p on ~b (v)vnodes, but"
                                      " failed on ~b (v)nodes\n",
                                      [Par, Val, SomeSucceeded, length(Multiple) - SomeSucceeded]);
                        _ ->
                            io:format("Failed to set ~s to ~p on all ~b (v)nodes\n",
                                      [Par, Val, length(Multiple)])
                    end
            end
        end,

    case {Item, Args} of
        {"rebuildtick", []} ->
            print_tictacaae_option(tictacaae_rebuildtick, Nodes);
        {"rebuildtick", [Arg1]} ->
            Msec = ensure_valid_range(Arg1, 0, 60*60*1000*1000),
            set_tictacaae_option(tictacaae_rebuildtick, Nodes, Msec);

        {"exchangetick", []} ->
            print_tictacaae_option(tictacaae_exchangetick, Nodes);
        {"exchangetick", [Arg1]} ->
            MSec = ensure_valid_range(Arg1, 0, 60*60*1000*1000),
            set_tictacaae_option(tictacaae_exchangetick, Nodes, MSec);

        {"maxresults", []} ->
            print_tictacaae_option(tictacaae_maxresults, Nodes);
        {"maxresults", [Arg1]} ->
            A = ensure_valid_range(Arg1, 1, 1000*1000),
            set_tictacaae_option(tictacaae_maxresults, Nodes, A);

        {"rangeboost", []} ->
            print_tictacaae_option(tictacaae_rangeboost, Nodes);
        {"rangeboost", [Arg1]} ->
            A = ensure_valid_range(Arg1, 0, 60*60*1000*1000),
            set_tictacaae_option(tictacaae_rangeboost, Nodes, A);

        {"rebuild_schedule", [Arg1, Arg2]} ->
            RS = {RW = ensure_valid_range(Arg1, 0, 5*365*24),  %% ~5 years in hours
                  RD = ensure_valid_range(Arg2, 0, 1*365*24*3600)},  %% one year
            PostSetResultF(
              set_rebuild_schedule(Nodes, Partitions, RS),
              "rebuild_schedule",
              io_lib:format("RW: ~b, RD: ~b", [RW, RD]));
        {"rebuild_schedule", []} ->
            FmtF = fun({ok, {RW, RD}}) ->
                           io_lib:format("RW: ~b, RD: ~b", [RW, RD]);
                      ({error, Reason}) ->
                           io_lib:format("(error: ~p)", [Reason])
                   end,
            [io:format("rebuild_schedule on ~s/~b is: ~s\n", [N, P, FmtF(Res)])
             || {Res, {P, N}} <- get_rebuild_schedule(Nodes, Partitions)],
            ok;

        {"storeheads", [Arg1]} ->
            Val = list_to_boolean(Arg1),
            PostSetResultF(
              set_storeheads(Nodes, Partitions, Val),
              "storeheads",
              Val);
        {"storeheads", []} ->
            [io:format("tictacaae_storeheads on ~s/~b is: ~s\n", [N, P, Res])
             || {Res, {P, N}} <- get_storeheads(Nodes, Partitions)],
            ok;

        {"tokenbucket", [Arg1]} ->
            Val = list_to_boolean(Arg1),
            PostSetResultF(
              set_tokenbucket(Nodes, Partitions, Val),
              "tokenbucket",
              Val);
        {"tokenbucket", []} ->
            [io:format("tictacaae_tokenbucket on ~s/~b is: ~s\n", [N, P, Res])
             || {Res, {P, N}} <- get_tokenbucket(Nodes, Partitions)],
            ok;

        {"rebuild-soon", [Arg1]} ->
            AffectedVNodes = schedule_nextrebuild(Nodes, Partitions, list_to_integer(Arg1)),
            if length(Nodes) == 1 ->
                    io:format("scheduled rebuild of aae trees on ~b partition~s on ~s\n",
                              [length(AffectedVNodes), ending(AffectedVNodes), hd(Nodes)]);
               el/=se ->
                    io:format("scheduled rebuild of aae trees on ~b nodes\n",
                              [length(Nodes)])
            end;

        {"rebuild-now", []} ->
            AffectedVNodes = schedule_nextrebuild(Nodes, Partitions, 0),
            send_rebuildpoke(Nodes, Partitions),
            if length(Nodes) == 1 ->
                    io:format("rebuilding aae trees on ~b partition~s on ~s\n",
                              [length(AffectedVNodes), ending(AffectedVNodes), hd(Nodes)]);
               el/=se ->
                    io:format("rebuilding aae trees on ~b nodes\n",
                              [length(Nodes)])
            end;

        {"rebuildtreeworkers", [Arg1]} ->
            Val = ensure_valid_range(Arg1, 1, 500),
            PostSetResultF(
              set_worker_pool_size(Nodes, af1_pool, Val),
              "rebuildtreeworkers",
              integer_to_list(Val));
        {"rebuildtreeworkers", []} ->
            [io:format("rebuildtreeworkers on ~s is: ~b\n", [N, Res])
             || {Res, N} <- get_worker_pool_size(Nodes, af1_pool)],
            ok;

        {"aaefoldworkers", [Arg1]} ->
            Val = ensure_valid_range(Arg1, 1, 500),
            PostSetResultF(
              set_worker_pool_size(Nodes, af4_pool, Val),
              "aaefoldworkers",
              integer_to_list(Val));
        {"aaefoldworkers", []} ->
            [io:format("aaefoldworkers on ~s is: ~b\n", [N, Res])
             || {Res, N} <- get_worker_pool_size(Nodes, af4_pool)],
            ok;

        {"rebuildstoreworkers", [Arg1]} ->
            Val = ensure_valid_range(Arg1, 1, 500),
            PostSetResultF(
              set_worker_pool_size(Nodes, be_pool, Val),
              "rebuildstoreworkers",
              integer_to_list(Val));
        {"rebuildstoreworkers", []} ->
            [io:format("rebuildstoreworkers on ~s is: ~b\n", [N, Res])
             || {Res, N} <- get_worker_pool_size(Nodes, be_pool)],
            ok;

        {"treestatus", []} ->
            case {Nodes, Partitions} of
                {[N], all} when N == node() ->
                    print_aae_progress_report(Options);
                _ ->
                    io:format("treestatus option only supported on local node\n", [])
            end;

        _ ->
            tictacaae_cmd3(Item, {Options, Args})
    end.

list_to_boolean("true") -> true;
list_to_boolean("enabled") -> true;
list_to_boolean("on") -> true;
list_to_boolean("false") -> false;
list_to_boolean("disabled") -> false;
list_to_boolean("off") -> false.

print_tictacaae_option(A, Nodes) ->
    [begin
         {ok, Current} = rpc:call(Node, application, get_env, [riak_kv, A]),
         io:format("~s on ~s is: ~p\n", [A, Node, Current])
     end || Node <- Nodes],
    ok.

set_tictacaae_option(A, Nodes, V) ->
    [ok = rpc:call(Node, application, set_env, [riak_kv, A, V])
     || Node <- Nodes],
    ok.

schedule_nextrebuild(Nodes, Partitions, Delay) ->
    exec_command_on_vnodes(Nodes, Partitions, {aae_schedule_nextrebuild, [Delay]}).
get_rebuild_schedule(Nodes, Partitions) ->
    exec_command_on_vnodes(Nodes, Partitions, {aae_get_rebuild_schedule, []}).
set_rebuild_schedule(Nodes, Partitions, RS) ->
    exec_command_on_vnodes(Nodes, Partitions, {aae_set_rebuild_schedule, [RS]}).
get_storeheads(Nodes, Partitions) ->
    exec_command_on_vnodes(Nodes, Partitions, {aae_get_storeheads, []}).
set_storeheads(Nodes, Partitions, A) ->
    exec_command_on_vnodes(Nodes, Partitions, {aae_set_storeheads, [A]}).
get_tokenbucket(Nodes, Partitions) ->
    exec_command_on_vnodes(Nodes, Partitions, {aae_get_tokenbucket, []}).
set_tokenbucket(Nodes, Partitions, A) ->
    exec_command_on_vnodes(Nodes, Partitions, {aae_set_tokenbucket, [A]}).
send_rebuildpoke(Nodes, Partitions) ->
    exec_command_on_vnodes(Nodes, Partitions, {aae_rebuildpoke, []}).

exec_command_on_vnodes(Nodes, Partitions, {F, A}) ->
    lists:foldl(
      fun(Node, Q) ->
              VVNN = vnodes(Node, Partitions),
              Res = [{rpc:call(Node, riak_kv_vnode, F, [VN | A]), VN} || VN <- VVNN],
              Q ++ Res
      end, [], Nodes).
vnodes(Node, all) ->
    {ok, Ring} = rpc:call(Node, riak_core_ring_manager, get_my_ring, []),
    [VN || VN = {_, Owner} <- rpc:call(Node, riak_core_ring, all_owners, [Ring]), Owner =:= Node];
vnodes(Node, List) ->
    [{P, Node} || P <- List].

set_worker_pool_size(Nodes, Pool, A) ->
    [{rpc:call(N, riak_core_node_worker_pool, set_worker_pool_size, [Pool, A]), N} || N <- Nodes].
get_worker_pool_size(Nodes, Pool) ->
    [{rpc:call(N, riak_core_node_worker_pool, get_worker_pool_size, [Pool]), N} || N <- Nodes].


produce_aae_progress_report() ->
    VVSS =
        lists:append(
          [case sys:get_state(P) of
               {active, _CoreVnodeState = {state, Idx, riak_kv_vnode, VSx, _, _, _, _, _, _, _, _}} ->
                   [{Idx, VSx}];
               _ ->
                   []
           end || {_, P, _, _} <- supervisor:which_children(riak_core_vnode_sup)]),

    [begin
         AAECntrl = riak_kv_vnode:aae_controller(VNState),
         TictacRebuilding = riak_kv_vnode:aae_rebuilding(VNState),

         KeyStore = aae_controller:aae_get_key_store(AAECntrl),

         KeyStoreCurrentStatus = if is_pid(KeyStore) ->
                                         element(1, aae_keystore:store_currentstatus(KeyStore));
                                    el/=se ->
                                         not_running
                                 end,

         LastRebuild = case aae_keystore:store_last_rebuild(KeyStore) of
                           never ->
                               never;
                           TS ->
                               calendar:now_to_local_time(TS)
                       end,
         NextRebuild = calendar:now_to_local_time(
                         aae_controller:aae_nextrebuild(AAECntrl)),

         TreeCaches = [Pid || {_Preflist, Pid} <- aae_controller:aae_get_tree_caches(AAECntrl)],
         TotalDirtySegments = lists:sum(
                                [aae_treecache:cache_segment_count(P) || P <- TreeCaches]),
         InProgress = TictacRebuilding /= false,
         Status =
             case {LastRebuild, InProgress, NextRebuild} of
                 {never, false, Scheduled} when Scheduled /= undefined ->
                     unbuilt;
                 {Built, false, _} when Built /= never ->
                     built;
                 {Built, true, _} when Built /= never ->
                     rebuilding;
                 {never, true, _} ->
                     building
             end,
         [{partition, Idx},
          {key_store_current_status, KeyStoreCurrentStatus},
          {last_rebuild, time2s(LastRebuild)},
          {next_rebuild, time2s(NextRebuild)},
          {total_dirty_segments, TotalDirtySegments},
          {controller_pid, list_to_binary(pid_to_list(AAECntrl))},
          {status, Status}
         ]
     end || {Idx, VNState} <- VVSS].


print_aae_progress_report(Options) ->
    Report = produce_aae_progress_report(),
    Format = proplists:get_value(format, Options),
    aae_progress_report(Format, Report, Options).

aae_progress_report("json", Report, _) ->
    io:format("~s\n", [mochijson2:encode(Report)]);

aae_progress_report("table", Report, Options) ->
    ShowValue = extract_show(Options),
    Show = [list_to_atom(A) || A <- ShowValue],
    io:format("~52s  ~10s  ~21s  ~20s  ~15s  ~16s\n", ["Partition ID", "Status", "Last Rebuild Date", "Next Rebuild Date", "Controller PID", "Key Store Status"]),
    io:format("~52s  ~10s  ~21s  ~20s  ~15s  ~16s\n", ["----------------------------------------------------", "----------", "---------------------", "---------------------", "----------------", "----------------"]),
    [begin
         Idx = proplists:get_value(partition, M),
         LastRebuild = proplists:get_value(last_rebuild, M),
         NextRebuild = proplists:get_value(next_rebuild, M),
         ControllerPid = proplists:get_value(controller_pid, M),
         Status = proplists:get_value(status, M),
         KeyStoreCurrentStatus = proplists:get_value(key_store_current_status, M),
         case lists:member(Status, Show) of
             true ->
                 io:format("~52b  ~10s  ~21s  ~20s  ~15s  ~16s\n",
                           [Idx, Status, LastRebuild, NextRebuild, ControllerPid, KeyStoreCurrentStatus]);
             false ->
                 skip
         end
     end || M <- Report],
    ok.

tictacaae_cmd3(Item, {Options, Args}) ->
    DumpF =
        fun(Op, Fun) ->
                Outfile_ =
                    iolist_to_binary(
                      string:replace(
                        string:replace(
                          proplists:get_value(output, Options, ?DEFAULT_AAEFOLD_OUTFILE),
                          "%o", Op),
                        "%t", time2s(now))),
                Outfile =
                    case Outfile_ of
                        <<$/, _/binary>> ->
                            Outfile_;
                        _ ->
                            {ok, CWD} = file:get_cwd(),
                            filename:join([CWD, Outfile_])
                    end,
                spawn(
                  fun() ->
                          case file:open(Outfile, [write]) of
                              {ok, FD} ->
                                  io:format("Results will be written to ~s\n", [Outfile]),
                                  Fun(FD),
                                  file:close(FD);
                              {error, Reason} ->
                                  io:format("Failed to open \"~p\" for writing: ~p\n", [Outfile, Reason])
                          end
                  end),
                ok
        end,
    case {Item, Args} of
        {"fold", ["list-buckets", NVal]} ->
            DumpF(
              "list-buckets",
              fun(FD) ->
                      Query =
                          {list_buckets,
                           ensure_valid_range(NVal, 1, 999)
                          },
                      {ok, BB} = riak_client:aae_fold(Query),
                      Printable = [printable_bin(B) || B <- BB],
                      io:format(FD, "~s\n", [mochijson2:encode(Printable)])
              end);

        {"fold", ["find-keys", Bucket, KeyRange, ModifiedRange, FourthArg]} ->
            DumpF(
              "find-keys",
              fun(FD) ->
                      Query =
                          {find_keys,
                           fold_query_spec(bucket, Bucket),
                           fold_query_spec(key_range, KeyRange),
                           fold_query_spec(modified_range, ModifiedRange),
                           fold_query_spec(sibling_count_or_object_size, FourthArg)
                          },
                      {ok, KK} = riak_client:aae_fold(Query),
                      Printable = [#{<<"key">> => printable_bin(K),
                                     <<"sibling_count">> => SibCnt
                                    } || {_B, K, SibCnt} <- KK],
                      io:format(FD, "~s\n", [mochijson2:encode(Printable)])
              end);

        {"fold", ["count-keys", Bucket, KeyRange, ModifiedRange, FourthArg]} ->
            DumpF(
              "count-keys",
              fun(FD) ->
                      Query =
                          {find_keys,
                           fold_query_spec(bucket, Bucket),
                           fold_query_spec(key_range, KeyRange),
                           fold_query_spec(modified_range, ModifiedRange),
                           fold_query_spec(sibling_count_or_object_size, FourthArg)
                          },
                      {ok, KK} = riak_client:aae_fold(Query),
                      io:format(FD, "~b\n", [length(KK)])
              end);

        {"fold", ["find-tombstones", Bucket, KeyRange, Segments, ModifiedRange]} ->
            DumpF(
              "find-tombstones",
              fun(FD) ->
                      Query =
                          {find_tombs,
                           fold_query_spec(bucket, Bucket),
                           fold_query_spec(key_range, KeyRange),
                           fold_query_spec(segments, Segments),
                           fold_query_spec(modified_range, ModifiedRange)
                          },
                      {ok, TT} = riak_client:aae_fold(Query),
                      Printable = [#{bucket => printable_bin(B),
                                     key => printable_bin(K),
                                     vclock => printable_vclock(VC)} || {B, K, VC} <- TT],
                      io:format(FD, "~s\n", [mochijson2:encode(Printable)])
              end);

        {"fold", ["count-tombstones", Bucket, KeyRange, Segments, ModifiedRange]} ->
            DumpF(
              "count-tombstones",
              fun(FD) ->
                      Query =
                          {find_tombs,
                           fold_query_spec(bucket, Bucket),
                           fold_query_spec(key_range, KeyRange),
                           fold_query_spec(segments, Segments),
                           fold_query_spec(modified_range, ModifiedRange)
                          },
                      {ok, TT} = riak_client:aae_fold(Query),
                      io:format(FD, "~b\n", [length(TT)])
              end);

        {"fold", ["reap-tombstones", Bucket, KeyRange, Segments, ModifiedRange, ChangeMethod]} ->
            DumpF(
              "reap-tombstones",
              fun(FD) ->
                      Query =
                          {reap_tombs,
                           fold_query_spec(bucket, Bucket),
                           fold_query_spec(key_range, KeyRange),
                           fold_query_spec(segments, Segments),
                           fold_query_spec(modified_range, ModifiedRange),
                           fold_query_spec(change_method, ChangeMethod)
                          },
                      {ok, TT} = riak_client:aae_fold(Query),
                      io:format(FD, "~b\n", [TT])
              end);

        {"fold", ["object-stats", Bucket, KeyRange, ModifiedRange]} ->
            DumpF(
              "object-stats",
              fun(FD) ->
                      Query =
                          {object_stats,
                           fold_query_spec(bucket, Bucket),
                           fold_query_spec(key_range, KeyRange),
                           fold_query_spec(modified_range, ModifiedRange)
                          },
                      {ok, SS} = riak_client:aae_fold(Query),
                      TC = proplists:get_value(total_count, SS),
                      TS = proplists:get_value(total_size, SS),
                      Sizes = proplists:get_value(sizes, SS),
                      Siblings = proplists:get_value(siblings, SS),
                      io:format(FD, "~s\n", [mochijson2:encode(
                                               #{total_count => TC,
                                                 total_size => TS,
                                                 sizes => [#{min => Min,
                                                             max => Max} || {Min, Max} <- Sizes],
                                                 siblings => [#{min => Min,
                                                                max => Max} || {Min, Max} <- Siblings]
                                                })])
              end);

        {"fold", ["erase-keys", Bucket, KeyRange, Segments, ModifiedRange, ChangeMethod]} ->
            DumpF(
              "erase-keys",
              fun(FD) ->
                      Query =
                          {erase_keys,
                           fold_query_spec(bucket, Bucket),
                           fold_query_spec(key_range, KeyRange),
                           fold_query_spec(segments, Segments),
                           fold_query_spec(modified_range, ModifiedRange),
                           fold_query_spec(change_method, ChangeMethod)
                          },
                      {ok, Res} = riak_client:aae_fold(Query),
                      io:format(FD, "~b\n", [Res])
              end);

        {"fold", ["repair-keys", Bucket, KeyRange, ModifiedRange]} ->
            DumpF(
              "erase-keys",
              fun(FD) ->
                      Query =
                          {repair_keys_range,
                           fold_query_spec(bucket, Bucket),
                           fold_query_spec(key_range, KeyRange),
                           fold_query_spec(modified_range, ModifiedRange),
                           all
                          },
                      {ok, {_Tail, Count, all, _RBS}} = riak_client:aae_fold(Query),
                      io:format(FD, "~b\n", [Count])
              end);

        _ ->
            tictacaae_cmd_usage()
    end.

fold_query_spec(bucket, A) ->
    case string:split(A, "/") of
        [BT, B] ->
            case lists:last(BT) of
                $\\ ->
                    bin_from_maybe_hex(A);
                _ ->
                    {bin_from_maybe_hex(BT), bin_from_maybe_hex(B)}
            end;
        _ ->
            bin_from_maybe_hex(A)
    end;
fold_query_spec(key_range, "all") -> all;
fold_query_spec(key_range, A) ->
    [From, To] = string:split(A, ","),
    {bin_from_maybe_hex(From), bin_from_maybe_hex(To)};
fold_query_spec(modified_range, "all") -> all;
fold_query_spec(modified_range, A) ->
    [From, To] = string:split(A, ","),
    {date, calendar:rfc3339_to_system_time(From),
     calendar:rfc3339_to_system_time(To)};
fold_query_spec(segments, "all") -> all;
fold_query_spec(segments, A) ->
    [SegmentFilter_, TreeSize_] = string:split(A, ";"),
    SegmentFilter = [ensure_valid_range(S, 0, infinity)
                     || S <- string:split(SegmentFilter_, ",", all)],
    TreeSize = tree_size(TreeSize_),
    {segments, SegmentFilter, TreeSize};
fold_query_spec(sibling_count_or_object_size, A) ->
    case string:split(A, "=") of
        ["sibling_count", V] ->
            {sibling_count, ensure_valid_range(V, 0, infinity)};
        ["object_size", V] ->
            {object_size, ensure_valid_range(V, 0, infinity)}
    end;
fold_query_spec(change_method, A) ->
    case string:split(A, "=") of
        ["jobs", V] ->
            {jobs, ensure_valid_range(V, 1, infinity)};
        ["local"] ->
            local;
        ["count"] ->
            count
    end.

ensure_valid_range(V_, Min, infinity) ->
    case list_to_integer(V_) of
        V when V >= Min ->
            V;
        _ ->
            throw(arg_out_of_range)
    end;
ensure_valid_range(V_, Min, Max) ->
    case list_to_integer(V_) of
        V when V >= Min, V =< Max ->
            V;
        _ ->
            throw(arg_out_of_range)
    end.


printable_bin(K) ->
    case re:run(K, <<"[[:alnum:][:punct:]]+">>) of
        {match, [{0, N}]} when N == size(K) ->
            K;
        _ ->
            iolist_to_binary(["0x", mochihex:to_hex(K)])
    end.
bin_from_maybe_hex("0x" ++ A) -> mochihex:to_bin(A);
bin_from_maybe_hex(A) -> list_to_binary(A).

printable_vclock(A) ->
    base64:encode(riak_object:encode_vclock(A)).

tree_size("xxsmall") -> xxsmall;
tree_size("xsmall") -> xsmall;
tree_size("small") -> small;
tree_size("medium") -> medium;
tree_size("large") -> large;
tree_size("xlarge") -> xlarge.

time2s(never) ->
    never;
time2s(now) ->
    time2s(calendar:local_time());
time2s({{LRY, LRMo, LRD}, {LRH, LRMi, LRS}}) ->
    iolist_to_binary(
      io_lib:format("~4.10.0B-~2.10.0B-~2.10.0BT~2.10.0B:~2.10.0B:~2.10.0B",
                    [LRY, LRMo, LRD, LRH, LRMi, LRS])).

extract_nodes(Options) ->
    NN = [N || {node, N} <- Options],
    case lists:member("all", NN) of
        true ->
            [node() | nodes()];
        false ->
            lists:join(",", [list_to_existing_atom(N) || N <- NN])
    end.
extract_partitions(Options) ->
    PP = [P || {partition, P} <- Options],
    case lists:member("all", PP) of
        true ->
            all;
        false ->
            [list_to_integer(P) || P <- PP]
    end.
extract_show(Options) ->
    PP = string:split(lists:flatten(lists:join(",", [P || {show, P} <- Options])), ",", all),
    case lists:member("all", PP) of
        true ->
            ["unbuilt", "rebuilding", "building", "built"];
        false ->
            PP
    end.

ending([_]) -> "";
ending(_) -> "s".

%%%===================================================================
%%% Private
%%%===================================================================

validate_repair_2i_args(Args) ->
    case riak_kv_entropy_manager:enabled() of
        true ->
            parse_repair_2i_args(Args);
        false ->
            {error, aae_disabled}
    end.

parse_repair_2i_args(["--speed", DutyCycleStr | Partitions]) ->
    DutyCycle = parse_int(DutyCycleStr),
    case DutyCycle of
        undefined ->
            {error, io_lib:format("Invalid speed value (~s). It should be a " ++
                                  "number between 1 and 100",
                                  [DutyCycleStr])};
        _ ->
            parse_repair_2i_args(DutyCycle, Partitions)
    end;
parse_repair_2i_args(Partitions) ->
    parse_repair_2i_args(100, Partitions).

parse_repair_2i_args(DutyCycle, Partitions) ->
    case get_2i_repair_indexes(Partitions) of
        {ok, IdxList} ->
            {ok, IdxList, DutyCycle};
        {error, Reason} ->
            {error, Reason}
    end.

get_2i_repair_indexes([]) ->
    AllVNodes = riak_core_vnode_manager:all_vnodes(riak_kv_vnode),
    {ok, [Idx || {riak_kv_vnode, Idx, _} <- AllVNodes]};
get_2i_repair_indexes(IntStrs) ->
    {ok, NodeIdxList} = get_2i_repair_indexes([]),
    F =
    fun(_, {error, Reason}) ->
            {error, Reason};
       (IntStr, Acc) ->
            case parse_int(IntStr) of
                undefined ->
                    {error, io_lib:format("~s is not an integer\n", [IntStr])};
                Int ->
                    case lists:member(Int, NodeIdxList) of
                        true ->
                            Acc ++ [Int];
                        false ->
                            {error,
                             io_lib:format("Partition ~p does not belong"
                                           ++ " to this node\n",
                                           [Int])}
                    end
            end
    end,
    IdxList = lists:foldl(F, [], IntStrs),
    case IdxList of
        {error, Reason} ->
            {error, Reason};
        _ ->
            {ok, IdxList}
    end.

format_stats([], Acc) ->
    lists:reverse(Acc);
format_stats([{Stat, V}|T], Acc) ->
    format_stats(T, [io_lib:format("~p : ~p~n", [Stat, V])|Acc]).

atomify_nodestrs(Strs) ->
    lists:foldl(fun("local", Acc) -> [node()|Acc];
                   (NodeStr, Acc) -> try
                                         [list_to_existing_atom(NodeStr)|Acc]
                                     catch error:badarg ->
                                         io:format("Bad node: ~s\n", [NodeStr]),
                                         Acc
                                     end
                end, [], Strs).

print_vnode_statuses([]) ->
    ok;
print_vnode_statuses([{VNodeIndex, StatusData} | RestStatuses]) ->
    io:format("VNode: ~p~n", [VNodeIndex]),
    print_vnode_status(StatusData),
    io:format("~n"),
    print_vnode_statuses(RestStatuses).

print_vnode_status([]) ->
    ok;
print_vnode_status([{backend_status,
                     Backend,
                     StatusItem} | RestStatusItems]) ->
    if is_binary(StatusItem) ->
            StatusString = binary_to_list(StatusItem),
            io:format("Backend: ~p~nStatus: ~n~s~n",
                      [Backend, string:strip(StatusString)]);
       true ->
            io:format("Backend: ~p~nStatus: ~n~p~n",
                      [Backend, StatusItem])
    end,
    print_vnode_status(RestStatusItems);
print_vnode_status([StatusItem | RestStatusItems]) ->
    if is_binary(StatusItem) ->
            StatusString = binary_to_list(StatusItem),
            io:format("Status: ~n~s~n",
                      [string:strip(StatusString)]);
       true ->
            io:format("Status: ~n~p~n", [StatusItem])
    end,
    print_vnode_status(RestStatusItems).

bucket_error_xlate(Errors) when is_list(Errors) ->
    string:join(
      lists:map(fun bucket_error_xlate/1, Errors),
      "~n");
bucket_error_xlate({Property, not_integer}) ->
    [atom_to_list(Property), " must be an integer"];

%% `riak_kv_bucket:coerce_bool/1` allows for other values but let's
%% not encourage bad behavior
bucket_error_xlate({Property, not_boolean}) ->
    [atom_to_list(Property), " should be \"true\" or \"false\""];

bucket_error_xlate({Property, not_valid_quorum}) ->
    [atom_to_list(Property), " must be an integer or (one|quorum|all)"];
bucket_error_xlate({_Property, Error}) when is_list(Error)
                                            orelse is_binary(Error) ->
    Error;
bucket_error_xlate({Property, Error}) when is_atom(Error) ->
    [atom_to_list(Property), ": ", atom_to_list(Error)];
bucket_error_xlate({Property, Error}) ->
    [atom_to_list(Property), ": ", io_lib:format("~p", [Error])];
bucket_error_xlate(X) ->
    io_lib:format("~p", [X]).
