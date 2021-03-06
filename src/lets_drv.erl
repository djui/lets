%%% The MIT License
%%%
%%% Copyright (C) 2011 by Joseph Wayne Norton <norton@alum.mit.edu>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.

-module(lets_drv).

-include("lets.hrl").

%% External exports
-export([open/4
         , destroy/4
         , repair/4
         , insert/3
         , insert_new/3
         , delete/2
         , delete/3
         , delete_all_objects/2
         , lookup/3
         , first/2
         , next/3
         , info_memory/2
         , info_size/2
         , tab2list/2
        ]).


%%%----------------------------------------------------------------------
%%% Types/Specs/Records
%%%----------------------------------------------------------------------

-define(LETS_BADARG,              16#00).
-define(LETS_TRUE,                16#01).
-define(LETS_END_OF_TABLE,        16#02).

-define(LETS_OPEN6,               16#00).
-define(LETS_DESTROY6,            16#01).
-define(LETS_REPAIR6,             16#02).
-define(LETS_INSERT2,             16#03).
-define(LETS_INSERT3,             16#04).
-define(LETS_INSERT_NEW2,         16#05).
-define(LETS_INSERT_NEW3,         16#06).
-define(LETS_DELETE1,             16#07).
-define(LETS_DELETE2,             16#08).
-define(LETS_DELETE_ALL_OBJECTS1, 16#09).
-define(LETS_LOOKUP2,             16#0A).
-define(LETS_FIRST1,              16#0B).
-define(LETS_NEXT2,               16#0C).
-define(LETS_INFO_MEMORY1,        16#0D).
-define(LETS_INFO_SIZE1,          16#0E).


%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

init() ->
    Path =
        case code:priv_dir(lets) of
            {error, bad_name} ->
                "../priv/lib";
            Dir ->
                filename:join([Dir, "lib"])
        end,
    case erl_ddll:load_driver(Path, lets_drv) of
        ok -> ok;
        {error, already_loaded} -> ok;
        {error, permanent} -> ok;
        {error, {open_error, _}=Err} ->
            FormattedErr = erl_ddll:format_error(Err),
            error_logger:error_msg("Failed to load the driver library lets_drv. "
                                   ++ "Error: ~p, Path: ~p~n",
                                   [FormattedErr,
                                    filename:join(Path, lets_drv)
                                   ]),
            erlang:exit({Err, FormattedErr})
    end,
    open_port({spawn, "lets_drv"}, [binary]).

open(#tab{name=_Name, named_table=_Named, type=Type, protection=Protection}=Tab, Options, ReadOptions, WriteOptions) ->
    {value, {path,Path}, NewOptions} = lists:keytake(path, 1, Options),
    Drv = impl_open(Type, Protection, Path, NewOptions, ReadOptions, WriteOptions),
    %% @TODO implement named Drv (of sorts)
    Tab#tab{drv=Drv}.

destroy(#tab{type=Type, protection=Protection}, Options, ReadOptions, WriteOptions) ->
    {value, {path,Path}, NewOptions} = lists:keytake(path, 1, Options),
    impl_destroy(Type, Protection, Path, NewOptions, ReadOptions, WriteOptions).

repair(#tab{type=Type, protection=Protection}, Options, ReadOptions, WriteOptions) ->
    {value, {path,Path}, NewOptions} = lists:keytake(path, 1, Options),
    impl_repair(Type, Protection, Path, NewOptions, ReadOptions, WriteOptions).

insert(#tab{keypos=KeyPos, type=Type}, Drv, Object) when is_tuple(Object) ->
    Key = element(KeyPos,Object),
    Val = Object,
    impl_insert(Drv, encode(Type, Key), encode(Type, Val));
insert(#tab{keypos=KeyPos, type=Type}, Drv, Objects) when is_list(Objects) ->
    List = [{encode(Type, element(KeyPos,Object)), encode(Type, Object)} || Object <- Objects ],
    impl_insert(Drv, List).

insert_new(#tab{keypos=KeyPos, type=Type}, Drv, Object) when is_tuple(Object) ->
    Key = element(KeyPos,Object),
    Val = Object,
    impl_insert_new(Drv, encode(Type, Key), encode(Type, Val));
insert_new(#tab{keypos=KeyPos, type=Type}, Drv, Objects) when is_list(Objects) ->
    List = [{encode(Type, element(KeyPos,Object)), encode(Type, Object)} || Object <- Objects ],
    impl_insert_new(Drv, List).

delete(_Tab, Drv) ->
    impl_delete(Drv).

delete(#tab{type=Type}, Drv, Key) ->
    impl_delete(Drv, encode(Type, Key)).

delete_all_objects(_Tab, Drv) ->
    impl_delete_all_objects(Drv).

lookup(#tab{type=Type}, Drv, Key) ->
    case impl_lookup(Drv, encode(Type, Key)) of
        true ->
            [];
        Object when is_binary(Object) ->
            [decode(Type, Object)]
    end.

first(#tab{type=Type}, Drv) ->
    case impl_first(Drv) of
        '$end_of_table' ->
            '$end_of_table';
        Key ->
            decode(Type, Key)
    end.

next(#tab{type=Type}, Drv, Key) ->
    case impl_next(Drv, encode(Type, Key)) of
        '$end_of_table' ->
            '$end_of_table';
        Next ->
            decode(Type, Next)
    end.

info_memory(_Tab, Drv) ->
    case impl_info_memory(Drv) of
        Memory when is_integer(Memory) ->
            erlang:round(Memory / erlang:system_info(wordsize));
        Else ->
            Else
    end.

info_size(_Tab, Drv) ->
    impl_info_size(Drv).

tab2list(Tab, Drv) ->
    tab2list(Tab, Drv, impl_first(Drv), []).

tab2list(_Tab, _Drv, '$end_of_table', Acc) ->
    lists:reverse(Acc);
tab2list(#tab{type=Type}=Tab, Drv, Key, Acc) ->
    NewAcc =
        case impl_lookup(Drv, Key) of
            true ->
                %% @NOTE This is not an atomic operation
                Acc;
            Object when is_binary(Object) ->
                [decode(Type, Object)|Acc]
        end,
    tab2list(Tab, Drv, impl_next(Drv, Key), NewAcc).


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

encode(set, Term) ->
    term_to_binary(Term);
encode(ordered_set, Term) ->
    sext:encode(Term).

decode(set, Term) ->
    binary_to_term(Term);
decode(ordered_set, Term) ->
    sext:decode(Term).

impl_open(Type, Protection, Path, Options, ReadOptions, WriteOptions) ->
    Drv = init(),
    true = call(Drv, {?LETS_OPEN6, Type, Protection, Path, Options, ReadOptions, WriteOptions}),
    Drv.

impl_destroy(Type, Protection, Path, Options, ReadOptions, WriteOptions) ->
    Drv = init(),
    true = call(Drv, {?LETS_OPEN6, Type, Protection, Path, Options, ReadOptions, WriteOptions}),
    _ = port_close(Drv),
    _ = erl_ddll:unload(lets_drv),
    true.

impl_repair(Type, Protection, Path, Options, ReadOptions, WriteOptions) ->
    Drv = init(),
    true = call(Drv, {?LETS_REPAIR6, Type, Protection, Path, Options, ReadOptions, WriteOptions}),
    _ = port_close(Drv),
    _ = erl_ddll:unload(lets_drv),
    true.

impl_insert(Drv, Key, Object) ->
    call(Drv, {?LETS_INSERT3, Key, Object}).

impl_insert(Drv, List) ->
    call(Drv, {?LETS_INSERT2, List}).

impl_insert_new(Drv, Key, Object) ->
    call(Drv, {?LETS_INSERT_NEW3, Key, Object}).

impl_insert_new(Drv, List) ->
    call(Drv, {?LETS_INSERT_NEW2, List}).

impl_delete(Drv) ->
    Res = call(Drv, {?LETS_DELETE1}),
    _ = port_close(Drv),
    _ = erl_ddll:unload(lets_drv),
    Res.

impl_delete(Drv, Key) ->
    call(Drv, {?LETS_DELETE2, Key}).

impl_delete_all_objects(Drv) ->
    call(Drv, {?LETS_DELETE_ALL_OBJECTS1}).

impl_lookup(Drv, Key) ->
    call(Drv, {?LETS_LOOKUP2, Key}).

impl_first(Drv) ->
    call(Drv, {?LETS_FIRST1}).

impl_next(Drv, Key) ->
    call(Drv, {?LETS_NEXT2, Key}).

impl_info_memory(Drv) ->
    call(Drv, {?LETS_INFO_MEMORY1}).

impl_info_size(Drv) ->
    call(Drv, {?LETS_INFO_SIZE1}).

call(Drv, Tuple) ->
    Data = term_to_binary(Tuple),
    port_command(Drv, Data),
    receive
        {Drv, ?LETS_TRUE, Reply} ->
            Reply;
        {Drv, ?LETS_TRUE} ->
            true;
        {Drv, ?LETS_END_OF_TABLE} ->
            '$end_of_table';
        {Drv, ?LETS_BADARG} ->
            erlang:error(badarg, [Drv])
            %% after 1000 ->
            %%         receive X ->
            %%                 erlang:error(timeout, [Drv, X])
            %%         after 0 ->
            %%                 erlang:error(timeout, [Drv])
            %%         end
    end.
