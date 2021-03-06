%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2010-2013. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

-module(diameter_codec_test).

-compile(export_all).

%%
%% Test encode/decode of dictionary-related modules.
%%

-include("diameter.hrl").

-define(RFC3588, diameter_gen_base_rfc3588).
-define(RFC6733, diameter_gen_base_rfc6733).
-define(BOOL, [true, false]).

-define(A, list_to_atom).
-define(S, atom_to_list).

%% ===========================================================================
%% Interface.

base() ->
    [] = run([{?MODULE, [base, T]} || T <- [zero, decode]]).

gen(Mod) ->
    Fs = [{Mod, F, []} || F <- [name, id, vendor_id, vendor_name]],
    [] = run(Fs ++ [{?MODULE, [gen, Mod, T]} || T <- [messages,
                                                      command_codes,
                                                      avp_types,
                                                      grouped,
                                                      enum,
                                                      import_avps,
                                                      import_groups,
                                                      import_enums]]).

lib() ->
    Vs = {_,_} = values('Address'),
    [] = run([[fun lib/2, N, Vs] || N <- [1,2]]).

%% ===========================================================================
%% Internal functions.

lib(N, {_,_} = T) ->
    B = 1 == N rem 2,
    [] = run([[fun lib/2, A, B] || A <- element(N,T)]);

lib(IP, B) ->
    LA = tuple_to_list(IP),
    {SA,Fun} = ip(LA),
    [] = run([[fun lib/4, IP, B, Fun, A] || A <- [IP, SA]]).

lib(IP, B, Fun, A) ->
    try Fun(A) of
        IP when B ->
            ok
    catch
        error:_ when not B ->
            ok
    end.

ip([_,_,_,_] = A) ->
    [$.|S] = lists:append(["." ++ integer_to_list(N) || N <- A]),
    {S, fun diameter_lib:ipaddr/1};
ip([_,_,_,_,_,_,_,_] = A) ->
    [$:|S] = lists:flatten([":" ++ io_lib:format("~.16B", [N]) || N <- A]),
    {S, fun diameter_lib:ipaddr/1}.

%% ------------------------------------------------------------------------
%% base/1
%%
%% Test of diameter_types.
%% ------------------------------------------------------------------------

base(T) ->
    [] = run([{?MODULE, [base, T, F]} || F <- types()]).

%% Ensure that 'zero' values encode only zeros.
base(zero = T, F) ->
    B = diameter_types:F(encode, T),
    B = z(B);

%% Ensure that we can decode what we encode and vice-versa, and that
%% we can't decode invalid values.
base(decode, F) ->
    {Eq, Vs, Ns} = b(values(F)),
    [] = run([{?MODULE, [base_decode, F, Eq, V]}  || V <- Vs]),
    [] = run([{?MODULE, [base_invalid, F, Eq, V]} || V <- Ns]).

base_decode(F, Eq, Value) ->
    d(fun(X,V) -> diameter_types:F(X,V) end, Eq, Value).

base_invalid(F, Eq, Value) ->
    try
        base_decode(F, Eq, Value),
        exit(nok)
    catch
        error: _ ->
            ok
    end.

b({_,_,_} = T) ->
    T;
b({B,Vs})
  when is_atom(B) ->
    {B,Vs,[]};
b({Vs,Ns}) ->
    {true, Vs, Ns};
b(Vs) ->
    {true, Vs, []}.

types() ->
    [F || {F,2} <- diameter_types:module_info(exports)].

%% ------------------------------------------------------------------------
%% gen/2
%%
%% Test of generated encode/decode module.
%% ------------------------------------------------------------------------

gen(M, T) ->
    [] = run(lists:map(fun(X) -> {?MODULE, [gen, M, T, X]} end,
                       fetch(T, dict(M)))).

fetch(T, Spec) ->
    case orddict:find(T, Spec) of
        {ok, L} ->
            L;
        error ->
            []
    end.

gen(M, messages = T, {Name, Code, Flags, ApplId, Avps})
  when is_list(Name) ->
    gen(M, T, {?A(Name), Code, Flags, ApplId, Avps});

gen(M, messages, {Name, Code, Flags, _, _}) ->
    Rname = M:msg2rec(Name),
    Name = M:rec2msg(Rname),
    {Code, F, _} = M:msg_header(Name),
    0 = F band 2#00001111,
    Name = case M:msg_name(Code, lists:member('REQ', Flags)) of
               N when Name /= 'answer-message' ->
                   N;
               '' when Name == 'answer-message', (M == ?RFC3588
                                                  orelse M == ?RFC6733) ->
                   Name
           end,
    [] = arity(M, Name, Rname);

gen(M, command_codes, {Code, Req, Ans}) ->
    Msgs = orddict:fetch(messages, dict(M)),
    {_, Code, _, _, _} = lists:keyfind(Req, 1, Msgs),
    {_, Code, _, _, _} = lists:keyfind(Ans, 1, Msgs);

gen(M, avp_types = T, {Name, Code, Type, Flags})
  when is_list(Name) ->
    gen(M, T, {?A(Name), Code, ?A(Type), Flags});

gen(M, avp_types, {Name, Code, Type, _Flags}) ->
    {Code, Flags, VendorId} = M:avp_header(Name),
    0 = Flags band 2#00011111,
    V = undefined /= VendorId,
    V = 0 /= Flags band 2#10000000,
    {Name, Type} = M:avp_name(Code, VendorId),
    B = M:empty_value(Name),
    B = z(B),
    [] = avp_decode(M, Type, Name);

gen(M, grouped = T, {Name, Code, Vid, Avps})
  when is_list(Name) ->
    gen(M, T, {?A(Name), Code, Vid, Avps});

gen(M, grouped, {Name, _, _, _}) ->
    Rname = M:name2rec(Name),
    [] = arity(M, Name, Rname);

gen(M, enum = T, {Name, ED})
  when is_list(Name) ->
    gen(M, T, {?A(Name), lists:map(fun({E,D}) -> {?A(E), D} end, ED)});

gen(M, enum, {Name, ED}) ->
    [] = run([{?MODULE, [enum, M, Name, T]} || T <- ED]);

gen(M, Tag, {_Mod, L}) ->
    T = retag(Tag),
    [] = run([{?MODULE, [gen, M, T, I]} || I <- L]).

%% avp_decode/3

avp_decode(Mod, Type, Name) ->
    {Eq, Vs, _} = b(values(Type, Name, Mod)),
    [] = run([{?MODULE, [avp_decode, Mod, Name, Type, Eq, V]}
              || V <- v(Vs)]).

avp_decode(Mod, Name, Type, Eq, Value) ->
    d(fun(X,V) -> avp(Mod, X, V, Name, Type) end, Eq, Value).

avp(Mod, decode = X, V, Name, 'Grouped') ->
    {Rec, _} = Mod:avp(X, V, Name),
    Rec;
avp(Mod, X, V, Name, _) ->
    Mod:avp(X, V, Name).

%% v/1

%% List of values ...
v(Vs)
  when is_list(Vs) ->
    Vs;

%% .. or enumeration for grouped avps. This could be quite large
%% (millions of values) but since the avps are also tested
%% individually don't bother trying everything. Instead, choose a
%% reasonable number of values at random.
v(E) ->
    v(2000, E(0), E).

v(Max, Ord, E)
  when Ord =< Max ->
    diameter_enum:to_list(E);
v(Max, Ord, E) ->
    {M,S,U} = now(),
    random:seed(M,S,U),
    v(Max, Ord, E, []).

v(0, _, _, Acc) ->
    Acc;
v(N, Ord, E, Acc) ->
    v(N-1, Ord, E, [E(random:uniform(Ord)) | Acc]).

%% arity/3

arity(M, Name, Rname) ->
    Rec = M:'#new-'(Rname),
    [] = run([{?MODULE, [arity, M, Name, F, Rec]}
              || F <- M:'#info-'(Rname, fields)]).

arity(M, Name, AvpName, Rec) ->
    Def = M:'#get-'(AvpName, Rec),
    Def = case M:avp_arity(Name, AvpName) of
              1 ->
                  undefined;
              A when 0 /= A ->
                  []
          end.

%% enum/3

enum(M, Name, {_,E}) ->
    B = <<E:32>>,
    B = M:avp(encode, E, Name),
    E = M:avp(decode, B, Name).

retag(import_avps)   -> avp_types;
retag(import_groups) -> grouped;
retag(import_enums)  -> enum;

retag(avp_types) -> import_avps;
retag(enum)     -> import_enums.

%% ===========================================================================

d(F, Eq, V) ->
    B = F(encode, V),
    D = F(decode, B),
    V = if Eq ->    %% test for value equality ...
                D;
           true ->  %% ... or that encode/decode is idempotent
                D = F(decode, F(encode, D)),
                V
        end.

z(B) ->
    << <<0>> || <<_>> <= B >>.

%% values/1
%%
%% Return a list of base type values. Can also be wrapped in a tuple
%% with 'false' to indicate that encode followed by decode may not be
%% the identity map. (Although that this composition is idempotent is
%% tested.)

values('OctetString' = T) ->
    {["", atom_to_list(T)], [-1, 256]};

values('Integer32') ->
    Mx = (1 bsl 31) - 1,
    Mn = -1*Mx,
    {[Mn, 0, random(Mn,Mx), Mx], [Mn - 1, Mx + 1]};

values('Integer64') ->
    Mx = (1 bsl 63) - 1,
    Mn = -1*Mx,
    {[Mn, 0, random(Mn,Mx), Mx], [Mn - 1, Mx + 1]};

values('Unsigned32') ->
    M = (1 bsl 32) - 1,
    {[0, random(M), M], [-1, M + 1]};

values('Unsigned64') ->
    M = (1 bsl 64) - 1,
    {[0, random(M), M], [-1, M + 1]};

values('Float32') ->
    E = (1 bsl  8) - 2,
    F = (1 bsl 23) - 1,
    <<Mx:32/float>> = <<0:1, E:8, F:23>>,
    <<Mn:32/float>> = <<1:1, E:8, F:23>>,
    {[0.0, infinity, '-infinity', Mx, Mn], [0]};

values('Float64') ->
    E = (1 bsl 11) - 2,
    F = (1 bsl 52) - 1,
    <<Mx:64/float>> = <<0:1, E:11, F:52>>,
    <<Mn:64/float>> = <<1:1, E:11, F:52>>,
    {[0.0, infinity, '-infinity', Mx, Mn], [0]};

values('Address') ->
    {[{255,0,random(16#FF),1}, {65535,0,0,random(16#FFFF),0,0,0,1}],
     [{256,0,0,1}, {65536,0,0,0,0,0,0,1}]};

values('DiameterIdentity') ->
    {["x", "diameter.com"], [""]};

values('DiameterURI') ->
    {false, ["aaa" ++ S ++ "://diameter.se" ++ P ++ Tr ++ Pr
             || S  <- ["", "s"],
                P  <- ["", ":1234"],
                Tr <- ["" | [";transport=" ++ X
                             || X <- ["tcp", "sctp", "udp"]]],
                Pr <- ["" | [";protocol=" ++ X
                             || X <- ["diameter","radius","tacacs+"]]]]};

values(T)
  when T == 'IPFilterRule';
       T == 'QoSFilterRule' ->
    ["deny in 0 from 127.0.0.1 to 10.0.0.1"];

%% RFC 3629 defines the UTF-8 encoding of U+0000 through U+10FFFF with the
%% exception of U+D800 through U+DFFF.
values('UTF8String') ->
    {[[],
      lists:seq(0,16#1FF),
      [0,16#D7FF,16#E000,16#10FFFF],
      [random(16#D7FF), random(16#E000,16#10FFFF)]],
     [[-1],
      [16#D800],
      [16#DFFF],
      [16#110000]]};

values('Time') ->
    {[{{1968,1,20},{3,14,8}},    %% 19000101T000000 + 1 bsl 31
      {date(), time()},
      {{2036,2,7},{6,28,15}},
      {{2036,2,7},{6,28,16}},    %% 19000101T000000 + 2 bsl 31
      {{2104,2,26},{9,42,23}}],
     [{{1968,1,20},{3,14,7}},
      {{2104,2,26},{9,42,24}}]}. %% 19000101T000000 + 3 bsl 31

%% values/3
%%
%% Return list or enumerations of values for a given AVP. Can be
%% wrapped as for values/1.

values('Enumerated', Name, Mod) ->
    {_Name, Vals} = lists:keyfind(?S(Name), 1, types(enum, Mod)),
    lists:map(fun({_,N}) -> N end, Vals);

values('Grouped', Name, Mod) ->
    Rname = Mod:name2rec(Name),
    Rec = Mod:'#new-'(Rname),
    Avps = Mod:'#info-'(Rname, fields),
    Enum = diameter_enum:combine(lists:map(fun({_,Vs,_}) -> to_enum(Vs) end,
                                           [values(F, Mod) || F <- Avps])),
    {false, diameter_enum:append(group(Mod, Name, Rec, Avps, Enum))};

values(_, 'Framed-IP-Address', _) ->
    [{127,0,0,1}];

values(Type, _, _) ->
    values(Type).

to_enum(Vs)
  when is_list(Vs) ->
    diameter_enum:new(Vs);
to_enum(E) ->
    E.

%% values/2

values('AVP', _) ->
    {true, [#diameter_avp{code = 0, data = <<0>>}], []};

values(Name, Mod) ->
    Avps = types(avp_types, Mod),
    {_Name, _Code, Type, _Flags} = lists:keyfind(?S(Name), 1, Avps),
    b(values(?A(Type), Name, Mod)).

%% group/5
%%
%% Pack four variants of group values: tagged list containing all
%% values, the corresponding record, a minimal tagged list and the
%% coresponding record.

group(Mod, Name, Rec, Avps, Enum) ->
    lists:map(fun(B) -> group(Mod, Name, Rec, Avps, Enum, B) end,
              [{A,R} || A <- ?BOOL, R <- ?BOOL]).

group(Mod, Name, Rec, Avps, Enum, B) ->
    diameter_enum:map(fun(Vs) -> g(Mod, Name, Rec, Avps, Vs, B) end, Enum).

g(Mod, Name, Rec, Avps, Values, {All, AsRec}) ->
    {Tagged, []}
        = lists:foldl(fun(N, {A, [V|Vs]}) ->
                              {pack(All, Mod:avp_arity(Name, N), N, V, A), Vs}
                      end,
                      {[], Values},
                      Avps),
    g(AsRec, Mod, Tagged, Rec).

g(true, Mod, Vals, Rec) ->
    Mod:'#set-'(Vals, Rec);
g(false, _, Vals, _) ->
    Vals.

pack(true, Arity, Avp, Value, Acc) ->
    [all(Arity, Avp, Value) | Acc];
pack(false, Arity, Avp, Value, Acc) ->
    min(Arity, Avp, Value, Acc).

all(Mod, Name, Avp, V) ->
    all(Mod:avp_arity(Name, Avp), Avp, V).

all(1, Avp, V) ->
    {Avp, V};
all({0,'*'}, Avp, V) ->
    a(1, Avp, V);
all({N,'*'}, Avp, V) ->
    a(N, Avp, V);
all({_,N}, Avp, V) ->
    a(N, Avp, V).

a(N, Avp, V)
  when N /= 0 ->
    {Avp, lists:duplicate(N,V)}.

min(Mod, Name, Avp, V, Acc) ->
    min(Mod:avp_arity(Name, Avp), Avp, V, Acc).

min(1, Avp, V, Acc) ->
    [{Avp, V} | Acc];
min({0,_}, _, _, Acc) ->
    Acc;
min({N,_}, Avp, V, Acc) ->
    [{Avp, lists:duplicate(N,V)} | Acc].

%% types/2

types(T, Mod) ->
    types(T, retag(T), Mod).

types(T, IT, Mod) ->
    Dict = dict(Mod),
    fetch(T, Dict) ++ lists:flatmap(fun({_,As}) -> As end, fetch(IT, Dict)).

%% random/[12]

random(M) ->
    random(0,M).

random(Mn,Mx) ->
    seed(get({?MODULE, seed})),
    Mn + random:uniform(Mx - Mn + 1) - 1.

seed(undefined) ->
    put({?MODULE, seed}, true),
    random:seed(now());

seed(true) ->
    ok.

%% run/1
%%
%% Unravel nested badmatches resulting from [] matches on calls to
%% run/1 to make for more readable failures.

run(L) ->
    lists:flatmap(fun flatten/1, diameter_util:run(L)).

flatten({_, {{badmatch, [{_, {{badmatch, _}, _}} | _] = L}, _}}) ->
    L;
flatten(T) ->
    [T].

%% dict/1

dict(Mod) ->
    tl(Mod:dict()).
