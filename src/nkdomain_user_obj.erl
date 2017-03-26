%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc User Object

-module(nkdomain_user_obj).
-behavior(nkdomain_obj).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([create/4, login/3, find_referred/3]).
-export([object_get_info/0, object_mapping/0, object_syntax/1,
         object_api_syntax/3, object_api_allow/4, object_api_cmd/4]).
-export([user_pass/1]).

-include("nkdomain.hrl").

-define(LLOG(Type, Txt, Args),
    lager:Type("NkDOMAIN User "++Txt, Args)).


%% ===================================================================
%% Types
%% ===================================================================


-type login_opts() ::
    #{
        password => binary(),
        session_id => binary(),
        session_type => module(),
        session_pid => pid(),
        local => binary(),
        remote => binary(),
        login_meta => map()
    }.


%% ===================================================================
%% API
%% ===================================================================

%% @doc
%% Data must follow object's syntax
-spec create(nkservice:id(), nkdomain:id(), nkdomain:name(), map()) ->
    {ok, nkdomain:obj_id(), nkdomain:path(), pid()} | {error, term()}.

create(Srv, Domain, Name, Data) ->
    Opts = #{
        name => Name,
        type_obj => Data,
        aliases =>
            case Data of
                #{email:=Email} -> Email;
                _ -> []
            end
    },
    case nkdomain_obj_lib:make_obj(Srv, Domain, ?DOMAIN_USER, Opts) of
        {ok, Obj} ->
            case nkdomain:create(Srv, Obj, #{}) of
                {ok, ?DOMAIN_USER, ObjId, Path, Pid} ->
                    {ok, ObjId, Path, Pid};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @doc
-spec login(nkservice:id(), User::binary(), login_opts()) ->
    {ok, UserId::nkdomain:obj_id(), SessId::nkdomain:obj_id(), map()} |
    {error, user_not_found|term()}.

login(SrvId, Login, Opts) ->
    case do_load(SrvId, Login, Opts) of
        {ok, ObjId, UserPid} ->
            case do_login(UserPid, ObjId, Opts) of
                {ok, UserObjId} ->
                    case do_start_session(SrvId, UserObjId, Opts) of
                        {ok, SessId} ->
                            {ok, UserObjId, SessId, #{}};
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.

%% @doc
find_referred(SrvId, Id, Spec) ->
    case nkdomain:find(SrvId, Id) of
        {ok, _Type, ObjId, _Path, _Pid} ->
            SrvId:object_store_find_referred(SrvId, ObjId, Spec);
        {error, Error} ->
            {error, Error}
    end.





%% ===================================================================
%% nkdomain_obj behaviour
%% ===================================================================


%% @private
object_get_info() ->
    #{
        type => ?DOMAIN_USER
    }.


%% @private
object_mapping() ->
    #{
        name => #{
            type => text,
            fields => #{keyword => #{type=>keyword}}
        },
        surname => #{
            type => text,
            fields => #{keyword => #{type=>keyword}}
        },
        email => #{type => keyword},
        password => #{type => keyword}
    }.


%% @private
object_syntax(update) ->
    #{
        name => binary,
        surname => binary,
        password => fun ?MODULE:user_pass/1,
        email => binary
    };

object_syntax(load) ->
    (object_syntax(update))#{
        '__mandatory' => [name, surname]
    }.


%% @private
object_api_syntax(Sub, Cmd, Syntax) ->
    nkdomain_user_obj_syntax:api(Sub, Cmd, Syntax).


%% @private
object_api_allow(_Sub, _Cmd, _Data, State) ->
    {true, State}.


%% @private
object_api_cmd(Sub, Cmd, Data, State) ->
    nkdomain_user_obj_api:cmd(Sub, Cmd, Data, State).




%% ===================================================================
%% Internal
%% ===================================================================





%% ===================================================================
%% Internal
%% ===================================================================

%% @private
do_load(SrvId, Login, Opts) ->
    LoadOpts = maps:with([register], Opts),
    case nkdomain:load(SrvId, Login, LoadOpts) of
        {ok, ?DOMAIN_USER, ObjId, _Path, Pid} ->
            {ok, ObjId, Pid};
        _ ->
            case SrvId:object_store_find_alias(SrvId, Login) of
                {ok, N, [{?DOMAIN_USER, ObjId, _Path}|_]}->
                    case N > 1 of
                        true ->
                            ?LLOG(notice, "duplicated alias for ~s", [Login]);
                        false ->
                            ok
                    end,
                    case nkdomain:load(SrvId, ObjId, LoadOpts) of
                        {ok, ?DOMAIN_USER, ObjId, _Path, Pid} ->
                            {ok, ObjId, Pid};
                        _ ->
                            {error, user_not_found}
                    end;
                _ ->
                    {error, user_not_found}
            end
    end.


%% @private
do_login(Pid, ObjId, #{password:=Pass}) ->
    {ok, Pass2} = user_pass(Pass),
    Fun = fun(#obj_session{obj=Obj}) ->
        case Obj of
            #{?DOMAIN_USER:=#{password:=Pass2}} ->
                {ok, true};
            _ ->
                {ok, false}
        end
    end,
    case nkdomain_obj:sync_op(Pid, {apply, Fun}) of
        {ok, true} ->
            {ok, ObjId};
        {ok, false} ->
            {error, invalid_password};
        {error, Error} ->
            {error, Error}
    end;

do_login(_Pid, _ObjId, _Opts) ->
    {error, invalid_password}.


%% @private
do_start_session(SrvId, UserId, Opts) ->
    Pid = maps:get(session_pid, Opts),
    Opts1 = maps:with([session_id, local, remote], Opts),
    Opts2 = Opts1#{referred_id=>UserId, pid=>Pid},
    lager:error("Opts2: ~p", [Opts2]),
    case nkdomain_session_obj:create(SrvId, UserId, Opts2) of
        {ok, _Type, ObjId, _Path, _Pid} ->
            {ok, ObjId};
        {error, Error} ->
            {error, Error}
    end.



%% @doc Generates a password from an user password or hash
-spec user_pass(string()|binary()) ->
    {ok, binary()}.

user_pass(Pass) ->
    Pass2 = nklib_util:to_binary(Pass),
    case binary:split(Pass2, <<"!">>, [global]) of
        [<<"NKD">>, <<>>, P, <<>>] when byte_size(P) > 10 ->
            {ok, Pass2};
        _ ->
            {ok, make_pass(Pass2)}
    end.


%% @doc Generates a password from an user password
-spec make_pass(string()|binary()) ->
    binary().

make_pass(Pass) ->
    Pass2 = nklib_util:to_binary(Pass),
    Salt = <<"netcomposer">>,
    Iters = nkdomain_app:get(user_password_pbkdf2_iters),
    {ok, Pbkdf2} = pbkdf2:pbkdf2(sha, Pass2, Salt, Iters),
    Hash = nklib_util:lhash(Pbkdf2),
    <<"NKD!!", Hash/binary, "!">>.

