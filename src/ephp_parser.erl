-module(ephp_parser).
-author('manuel@altenwald.com').
-compile([warnings_as_errors, export_all]).

-export([parse/1, file/1]).

-include("ephp.hrl").
-include("ephp_parser.hrl").

-import(ephp_parser_expr, [
    expression/3, add_op/2, precedence/1
]).

file(File) ->
    {ok, Content} = file:read_file(File),
    parse(Content).

parse(Document) when is_list(Document) ->
    parse(list_to_binary(Document));
parse(Document) ->
    {_, _, Parsed} = document(Document, {root,1,1}, []),
    lists:reverse(Parsed).

document(<<>>, Pos, Parsed) ->
    {<<>>, Pos, Parsed};
document(<<"<?php",Rest/binary>>, {literal,_,_}=Pos, Parsed) ->
    {Rest, add_pos(Pos,5), Parsed};
document(<<"<?php",Rest/binary>>, Pos, Parsed) ->
    {Rest0,Pos0,NParsed} = code(Rest, normal_level(add_pos(Pos,5)), []),
    case NParsed of
        [] ->
            document(Rest0, Pos0, Parsed);
        _ ->
            Eval = add_line(#eval{statements=lists:reverse(NParsed)}, Pos),
            document(Rest0,Pos0,[Eval|Parsed])
    end;
document(<<"<?=",Rest/binary>>, Pos, Parsed) ->
    NewPos = code_value_level(add_pos(Pos,3)),
    {Rest0,Pos0,Text} = code(Rest, NewPos, []),
    document(Rest0, copy_level(Pos,Pos0), [get_print(Text,NewPos)|Parsed]);
document(<<"<?",Rest/binary>>, {literal,_,_}=Pos, Parsed) ->
    %% TODO: if short is not permitted, use as text
    {Rest, add_pos(Pos,2), Parsed};
document(<<"<?",Rest/binary>>, Pos, Parsed) ->
    %% TODO: if short is not permitted, use as text
    {Rest0,Pos0,NParsed} = code(Rest, normal_level(add_pos(Pos,2)), []),
    case NParsed of
        [] ->
            document(Rest0, Pos0, Parsed);
        _ ->
            Eval = add_line(#eval{statements=lists:reverse(NParsed)}, Pos),
            document(Rest0,Pos0,[Eval|Parsed])
    end;
document(<<"\n",Rest/binary>>, Pos, Parsed) ->
    document(Rest, new_line(Pos), add_to_text(<<"\n">>, Pos, Parsed));
document(<<L:1/binary,Rest/binary>>, Pos, Parsed) ->
    document(Rest, add_pos(Pos,1), add_to_text(L, Pos, Parsed)).

copy_level({Level,_,_}, {_,Row,Col}) -> {Level,Row,Col}.

code(<<>>, Pos, Parsed) ->
    {<<>>, Pos, Parsed};
code(<<B:8,R:8,E:8,A:8,K:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(B,$B,$b) andalso ?OR(R,$R,$r) andalso ?OR(E,$E,$e) andalso
        ?OR(A,$A,$a) andalso ?OR(K,$K,$k) andalso
        (not (?IS_SPACE(SP) orelse ?IS_NUMBER(SP))) ->
    code(<<SP:8,Rest/binary>>, add_pos(Pos,5), [break|Parsed]);
code(<<C:8,O:8,N:8,T:8,I:8,N:8,U:8,E:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(C,$C,$c) andalso ?OR(O,$O,$o) andalso ?OR(N,$N,$n) andalso
        ?OR(T,$T,$t) andalso ?OR(I,$I,$i) andalso ?OR(U,$U,$u) andalso
        ?OR(E,$E,$e) andalso (not (?IS_SPACE(SP) orelse ?IS_NUMBER(SP))) ->
    code(<<SP:8,Rest/binary>>, add_pos(Pos,8), [continue|Parsed]);
code(<<R:8,E:8,T:8,U:8,R:8,N:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(R,$R,$r) andalso ?OR(E,$E,$e) andalso ?OR(T,$T,$t) andalso
        ?OR(U,$U,$u) andalso ?OR(N,$N,$n) andalso
        (not (?IS_ALPHA(SP) orelse ?IS_NUMBER(SP))) ->
    {Rest0, Pos0, Return} = expression(<<SP:8,Rest/binary>>, add_pos(Pos,6), []),
    case Return of
        [] -> code(Rest0, Pos0, [add_line(#return{}, Pos)|Parsed]);
        _ -> code(Rest0, Pos0, [add_line(#return{value=Return}, Pos)|Parsed])
    end;
code(<<"@",Rest/binary>>, Pos, Parsed) ->
    {Rest0, Pos0, RParsed0} = code(Rest, add_pos(Pos,1), []),
    [ToSilent|Parsed0] = lists:reverse(RParsed0),
    Silent = {silent, ToSilent},
    {Rest0, Pos0, lists:reverse([Silent|Parsed0]) ++ Parsed};
code(<<G:8,L:8,O:8,B:8,A:8,L:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(G,$G,$g) andalso ?OR(L,$L,$l) andalso ?OR(O,$O,$o) andalso
        ?OR(B,$B,$b) andalso ?OR(A,$A,$a) andalso
        (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP)) ->
    {Rest0, Pos0} = remove_spaces(Rest, add_pos(Pos,7)),
    {Rest1, Pos1, [Global]} = st_global(Rest0, Pos0, []),
    code(Rest1, copy_level(Pos, Pos1), [Global|Parsed]);
code(<<"}",Rest/binary>>, {code_block,_,_}=Pos, Parsed) ->
    {Rest, add_pos(Pos,1), lists:reverse(Parsed)};
code(<<"}",Rest/binary>>, {switch_block,_,_}=Pos, Parsed) ->
    {Rest, add_pos(Pos,1), lists:reverse(switch_case_block(Parsed))};
code(<<E:8,N:8,D:8,I:8,F:8,SP:8,Rest/binary>>, {if_old_block,_,_}=Pos, Parsed)
    when
        ?OR(E,$E,$e) andalso ?OR(N,$N,$n) andalso ?OR(D,$D,$d) andalso
        ?OR(I,$I,$i) andalso ?OR(F,$F,$f) andalso
        (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP) orelse SP =:= $;) ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, add_pos(Pos,5)),
    {Rest0, Pos0, lists:reverse(Parsed)};
code(<<E:8,N:8,D:8,F:8,O:8,R:8,E:8,A:8,C:8,H:8,SP:8,Rest/binary>>,
     {foreach_old_block,_,_}=Pos, Parsed) when
        ?OR(E,$E,$e) andalso ?OR(N,$N,$n) andalso ?OR(D,$D,$d) andalso
        ?OR(F,$F,$f) andalso ?OR(O,$O,$o) andalso ?OR(R,$R,$r) andalso
        ?OR(A,$A,$a) andalso ?OR(C,$C,$c) andalso ?OR(H,$H,$h) andalso
        (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP) orelse SP =:= $;) ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, add_pos(Pos,10)),
    {Rest0, Pos0, lists:reverse(Parsed)};
code(<<E:8,N:8,D:8,F:8,O:8,R:8,SP:8,Rest/binary>>,
     {for_old_block,_,_}=Pos, Parsed) when
        ?OR(E,$E,$e) andalso ?OR(N,$N,$n) andalso ?OR(D,$D,$d) andalso
        ?OR(F,$F,$f) andalso ?OR(O,$O,$o) andalso ?OR(R,$R,$r) andalso
        (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP) orelse SP =:= $;) ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, add_pos(Pos,6)),
    {Rest0, Pos0, lists:reverse(Parsed)};
code(<<E:8,N:8,D:8,W:8,H:8,I:8,L:8,E:8,SP:8,Rest/binary>>,
     {while_old_block,_,_}=Pos, Parsed) when
        ?OR(E,$E,$e) andalso ?OR(N,$N,$n) andalso ?OR(D,$D,$d) andalso
        ?OR(W,$W,$w) andalso ?OR(H,$H,$h) andalso ?OR(I,$I,$i) andalso
        ?OR(L,$L,$l) andalso
        (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP) orelse SP =:= $;) ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, add_pos(Pos,8)),
    {Rest0, Pos0, lists:reverse(Parsed)};
code(<<A:8,_/binary>> = Rest, {code_statement,_,_}=Pos, Parsed)
        when A =:= $; orelse A =:= $} ->
    {Rest, Pos, Parsed};
code(<<T:8,R:8,U:8,E:8,SP:8,Rest/binary>>, Pos, Parsed)
        when ?OR(T,$t,$T) andalso ?OR(R,$r,$R) andalso ?OR(U,$u,$U)
        andalso ?OR(E,$e,$E) andalso (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP)) ->
    {Rest0, Pos0, Exp} = expression(Rest, Pos, [{op,[true]}]),
    code(Rest0, copy_level(Pos, Pos0), [Exp|Parsed]);
code(<<F:8,A:8,L:8,S:8,E:8,SP:8,Rest/binary>>, Pos, Parsed)
        when ?OR(F,$f,$F) andalso ?OR(A,$a,$A) andalso ?OR(L,$l,$L)
        andalso ?OR(S,$s,$S) andalso ?OR(E,$e,$E)
        andalso (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP)) ->
    {Rest0, Pos0, Exp} = expression(Rest, Pos, [{op,[false]}]),
    code(Rest0, copy_level(Pos, Pos0), [Exp|Parsed]);
code(<<I:8,F:8,SP:8,Rest/binary>>, Pos, Parsed)
        when ?OR(I,$i,$I) andalso ?OR(F,$f,$F) andalso ?OR(SP,32,$() ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, Pos),
    {Rest1, Pos1, NewParsed} = st_if(Rest0, Pos0, Parsed),
    code(Rest1, copy_level(Pos,Pos1), NewParsed);
code(<<W:8,H:8,I:8,L:8,E:8,SP:8,Rest/binary>>, Pos, Parsed)
        when ?OR(W,$w,$W) andalso ?OR(H,$h,$H) andalso ?OR(I,$i,$I)
        andalso ?OR(L,$l,$L) andalso ?OR(E,$e,$E) andalso ?OR(SP,32,$() ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, add_pos(Pos,5)),
    {Rest1, Pos1, NewParsed} = st_while(Rest0, Pos0, Parsed),
    code(Rest1, copy_level(Pos,Pos1), NewParsed);
code(<<D:8,O:8,SP:8,Rest/binary>>, Pos, Parsed)
        when ?OR(D,$d,$D) andalso ?OR(O,$o,$O) andalso
        (?IS_SPACE(SP) orelse ?OR(SP,${,$:)) ->
    {Rest0, Pos0, [DoWhile]} = st_do_while(Rest, add_pos(Pos,3), []),
    code(Rest0, copy_level(Pos,Pos0), [DoWhile|Parsed]);
code(<<F:8,O:8,R:8,E:8,A:8,C:8,H:8,SP:8,Rest/binary>>, Pos, Parsed)
        when ?OR(F,$f,$F) andalso ?OR(O,$o,$O) andalso ?OR(R,$r,$R)
        andalso ?OR(E,$e,$E) andalso ?OR(A,$a,$A) andalso ?OR(C,$c,$C)
        andalso ?OR(H,$h,$H)
        andalso (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP) orelse SP =:= $() ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>,Pos),
    {Rest1, Pos1, NewParsed} = st_foreach(Rest0, Pos0, Parsed),
    code(Rest1, copy_level(Pos, Pos1), NewParsed);
code(<<F:8,O:8,R:8,SP:8,Rest/binary>>, Pos, Parsed)
        when ?OR(F,$f,$F) andalso ?OR(O,$o,$O) andalso ?OR(R,$r,$R)
        andalso (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP) orelse SP =:= $() ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>,Pos),
    {Rest1, Pos1, NewParsed} = st_for(Rest0, Pos0, Parsed),
    code(Rest1, copy_level(Pos, Pos1), NewParsed);
code(<<E:8,L:8,S:8,E:8,SP:8,_/binary>> = Rest, {if_old_block,_,_}=Pos, Parsed)
        when ?OR(E,$e,$E) andalso ?OR(L,$l,$L) andalso ?OR(S,$s,$S)
        andalso (SP =:= $: orelse ?IS_SPACE(SP) orelse ?OR(SP,$i,$I)) ->
    {Rest, Pos, Parsed};
code(<<E:8,L:8,S:8,E:8,SP:8,Rest/binary>>, Pos, [#if_block{}|_]=Parsed) when
        ?OR(E,$e,$E) andalso ?OR(L,$l,$L) andalso ?OR(S,$s,$S) andalso
        (?OR(SP,${,$:) orelse ?IS_SPACE(SP) orelse ?OR(SP,$i,$I) orelse
         ?IS_NEWLINE(SP)) ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, Pos),
    {Rest1, Pos1, NewParsed} = st_else(Rest0, Pos0, Parsed),
    code(Rest1, copy_level(Pos, Pos1), NewParsed);
code(<<S:8,W:8,I:8,T:8,C:8,H:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(S,$S,$s) andalso ?OR(W,$W,$w) andalso ?OR(I,$I,$i) andalso
        ?OR(T,$T,$t) andalso ?OR(C,$C,$c) andalso ?OR(H,$H,$h) andalso
        (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP) orelse SP =:= $() ->
    {<<"(",_/binary>> = Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, Pos),
    {Rest1, Pos1, NewParsed} = st_switch(Rest0, add_pos(Pos0,6), Parsed),
    code(Rest1, copy_level(Pos, Pos1), NewParsed);
code(<<C:8,A:8,S:8,E:8,SP:8,Rest/binary>>, {switch_block,_,_}=Pos, Parsed) when
        ?OR(C,$C,$c) andalso ?OR(A,$A,$a) andalso ?OR(S,$S,$s) andalso
        ?OR(E,$E,$e) andalso (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP)) ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, add_pos(Pos,4)),
    NewPos = switch_label_level(Pos0),
    {<<":",Rest1/binary>>, Pos1, Exp} = expression(Rest0, NewPos, []),
    NewParsed = [add_line(#switch_case{
        label=Exp,
        code_block=[]
    }, Pos)|switch_case_block(Parsed)],
    code(Rest1, copy_level(Pos, add_pos(Pos1,1)), NewParsed);
code(<<D:8,E:8,F:8,A:8,U:8,L:8,T:8,SP:8,Rest/binary>>,
     {switch_block,_,_}=Pos, Parsed) when
        ?OR(D,$D,$d) andalso ?OR(E,$E,$e) andalso ?OR(F,$F,$f) andalso
        ?OR(A,$A,$a) andalso ?OR(U,$U,$u) andalso ?OR(L,$L,$l) andalso
        ?OR(T,$T,$t) andalso
        (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP) orelse SP =:= $:) ->
    {<<":",Rest0/binary>>, Pos0} = remove_spaces(<<SP:8,Rest/binary>>,
                                                 add_pos(Pos,4)),
    NewParsed = [add_line(#switch_case{
        label=default,
        code_block=[]
    }, Pos)|switch_case_block(Parsed)],
    code(Rest0, copy_level(Pos, add_pos(Pos0,1)), NewParsed);
code(<<A:8,B:8,S:8,T:8,R:8,A:8,C:8,T:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(A,$A,$a) andalso ?OR(B,$B,$b) andalso ?OR(S,$S,$s) andalso
        ?OR(T,$T,$t) andalso ?OR(R,$R,$r) andalso ?OR(C,$C,$c) andalso
        (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP)) ->
    {Rest0, Pos0, [#class{}=C|Parsed0]} = code(Rest, add_pos(Pos,9), []),
    {Rest0, Pos0, [C#class{type=abstract}|Parsed0] ++ Parsed};
code(<<C:8,L:8,A:8,S:8,S:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(C,$C,$c) andalso ?OR(L,$L,$l) andalso ?OR(A,$A,$a) andalso
        ?OR(S,$S,$s) andalso (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP)) ->
    Class = add_line(#class{}, Pos),
    {Rest0, Pos0, Class0} =
        ephp_parser_class:st_class(<<SP:8,Rest/binary>>, add_pos(Pos,5), Class),
    code(Rest0, Pos0, [Class0|Parsed]);
code(<<E:8,C:8,H:8,O:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(E,$e,$E) andalso ?OR(C,$c,$C) andalso ?OR(H,$h,$H) andalso
        ?OR(O,$o,$O) andalso ?OR(SP,32,$() ->
    {Rest0, Pos0, Exp} = expression(<<SP:8,Rest/binary>>,
                                     arg_level(add_pos(Pos,5)), []),
    % FIXME if we detect an OR or AND expression, we put around print
    Print = case Exp of
        #operation{type = Type} when Type =:= 'or' orelse Type =:= 'and' ->
            Exp#operation{
                expression_left = get_print(Exp#operation.expression_left, Pos)
            };
        _ ->
            get_print(Exp, Pos)
    end,
    code(Rest0, copy_level(Pos, Pos0), [Print|Parsed]);
code(<<P:8,R:8,I:8,N:8,T:8,SP:8,Rest/binary>>, Pos, Parsed)
        when ?OR(P,$p,$P) andalso ?OR(R,$r,$R) andalso ?OR(I,$i,$I)
        andalso ?OR(N,$n,$N) andalso ?OR(T,$t,$T) andalso ?OR(SP,32,$() ->
    {Rest0, Pos0, Exp} = expression(<<SP:8,Rest/binary>>,
                                     arg_level(add_pos(Pos,6)), []),
    % FIXME if we detect an OR or AND expression, we put around print
    Print = case Exp of
        #operation{type = Type} when Type =:= 'or' orelse Type =:= 'and' ->
            Exp#operation{
                expression_left = get_print(Exp#operation.expression_left, Pos)
            };
        _ ->
            get_print(Exp, Pos)
    end,
    code(Rest0, copy_level(Pos, Pos0), [Print|Parsed]);
code(<<C:8,O:8,N:8,S:8,T:8,SP:8,Rest/binary>>, Pos, Parsed)
        when ?OR(C,$c,$C) andalso ?OR(O,$o,$O) andalso ?OR(N,$n,$N)
        andalso ?OR(S,$s,$S) andalso ?OR(T,$t,$T) andalso ?IS_SPACE(SP) ->
    {Rest0, Pos0, #assign{variable=#constant{}=Const, expression=Value}} =
        expression(Rest, add_pos(Pos,6), []),
    Constant = Const#constant{type=define, value=Value},
    code(Rest0, copy_level(Pos, Pos0), [Constant|Parsed]);
code(<<F:8,U:8,N:8,C:8,T:8,I:8,O:8,N:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(F,$F,$f) andalso ?OR(U,$U,$u) andalso ?OR(N,$N,$n) andalso
        ?OR(C,$C,$c) andalso ?OR(T,$T,$t) andalso ?OR(I,$I,$i) andalso
        ?OR(O,$O,$o) andalso ?IS_SPACE(SP) ->
    {Rest0, Pos0, [#function{}=Function]} =
        ephp_parser_func:st_function(Rest, add_pos(Pos,9), []),
    code(Rest0, copy_level(Pos, Pos0), Parsed ++ [Function]);
code(<<F:8,U:8,N:8,C:8,T:8,I:8,O:8,N:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(F,$F,$f) andalso ?OR(U,$U,$u) andalso ?OR(N,$N,$n) andalso
        ?OR(C,$C,$c) andalso ?OR(T,$T,$t) andalso ?OR(I,$I,$i) andalso
        ?OR(O,$O,$o) andalso ?IS_NEWLINE(SP) ->
    NewPos = new_line(add_pos(Pos,8)),
    {Rest0, Pos0, #function{}=Function} =
        ephp_parser_func:st_function(Rest, NewPos, []),
    code(Rest0, copy_level(Pos, Pos0), Parsed ++ [Function]);
code(<<"?>\n",Rest/binary>>, {code_value,_,_}=Pos, [Parsed]) ->
    {Rest, new_line(add_pos(Pos,2)), Parsed};
code(<<"?>",Rest/binary>>, {code_value,_,_}=Pos, [Parsed]) ->
    {Rest, add_pos(Pos,2), Parsed};
code(<<"?>\n",Rest/binary>>, {L,_,_}=Pos, Parsed) when
        L =:= code_block orelse L =:= if_old_block orelse
        L =:= while_old_block orelse L =:= for_old_block orelse
        L =:= foreach_old_block orelse L =:= switch_block ->
    NewPos = new_line(literal_level(add_pos(Pos,2))),
    {Rest0, Pos0, Text} = document(Rest, NewPos, []),
    code(Rest0, copy_level(Pos,Pos0), Text ++ Parsed);
code(<<"?>",Rest/binary>>, {L,_,_}=Pos, Parsed) when
        L =:= code_block orelse L =:= if_old_block orelse
        L =:= while_old_block orelse L =:= for_old_block orelse
        L =:= foreach_old_block orelse L =:= switch_block ->
    {Rest0, Pos0, Text} = document(Rest, literal_level(add_pos(Pos,2)), []),
    code(Rest0, copy_level(Pos,Pos0), Text ++ Parsed);
code(<<"?>\n",Rest/binary>>, Pos, Parsed) ->
    {Rest, new_line(add_pos(Pos,2)), Parsed};
code(<<"?>",Rest/binary>>, Pos, Parsed) ->
    {Rest, add_pos(Pos,2), Parsed};
code(<<"//",Rest/binary>>, Pos, Parsed) ->
    {Rest0, Pos0, _} = comment_line(Rest, Pos, Parsed),
    code(Rest0, Pos0, Parsed);
code(<<"#",Rest/binary>>, Pos, Parsed) ->
    {Rest0, Pos0, _} = comment_line(Rest, Pos, Parsed),
    code(Rest0, Pos0, Parsed);
code(<<"/*",Rest/binary>>, Pos, Parsed) ->
    {Rest0, Pos0, _} = comment_block(Rest, Pos, Parsed),
    code(Rest0, Pos0, Parsed);
code(<<"<<<",_/binary>> = Rest, Pos, Parsed) ->
    {Rest0, Pos0, S} = ephp_parser_string:string(Rest,Pos,[]),
    code(Rest0, copy_level(Pos, Pos0), [S|Parsed]);
code(<<I:8,N:8,C:8,L:8,U:8,D:8,E:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(I,$I,$i) andalso ?OR(N,$N,$n) andalso ?OR(C,$C,$c) andalso
        ?OR(L,$L,$l) andalso ?OR(U,$U,$u) andalso ?OR(D,$D,$d) andalso
        ?OR(E,$E,$e) andalso ?OR(SP,$(,32) ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, add_pos(Pos, 7)),
    {Rest1, Pos1, Exp} = expression(Rest0, Pos0, []),
    Include = add_line(#call{name = <<"include">>, args=[Exp]}, Pos),
    code(Rest1, Pos1, [Include|Parsed]);
code(<<I:8,N:8,C:8,L:8,U:8,D:8,E:8,$_,O:8,N:8,C:8,E:8,SP:8,Rest/binary>>,
     Pos, Parsed) when
        ?OR(I,$I,$i) andalso ?OR(N,$N,$n) andalso ?OR(C,$C,$c) andalso
        ?OR(L,$L,$l) andalso ?OR(U,$U,$u) andalso ?OR(D,$D,$d) andalso
        ?OR(E,$E,$e) andalso ?OR(O,$O,$o) andalso ?OR(SP,$(,32) ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, add_pos(Pos, 7)),
    {Rest1, Pos1, Exp} = expression(Rest0, Pos0, []),
    Include = add_line(#call{name = <<"include_once">>, args=[Exp]}, Pos),
    code(Rest1, Pos1, [Include|Parsed]);
code(<<R:8,E:8,Q:8,U:8,I:8,R:8,E:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(R,$R,$r) andalso ?OR(E,$E,$e) andalso ?OR(Q,$Q,$q) andalso
        ?OR(U,$U,$u) andalso ?OR(I,$I,$i) andalso ?OR(SP,$(,32) ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, add_pos(Pos, 7)),
    {Rest1, Pos1, Exp} = expression(Rest0, Pos0, []),
    Include = add_line(#call{name = <<"require">>, args=[Exp]}, Pos),
    code(Rest1, Pos1, [Include|Parsed]);
code(<<R:8,E:8,Q:8,U:8,I:8,R:8,E:8,$_,O:8,N:8,C:8,E:8,SP:8,Rest/binary>>,
     Pos, Parsed) when
        ?OR(R,$R,$r) andalso ?OR(E,$E,$e) andalso ?OR(Q,$Q,$q) andalso
        ?OR(U,$U,$u) andalso ?OR(I,$I,$i) andalso ?OR(O,$O,$o) andalso
        ?OR(N,$N,$n) andalso ?OR(C,$C,$c) andalso ?OR(SP,$(,32) ->
    {Rest0, Pos0} = remove_spaces(<<SP:8,Rest/binary>>, add_pos(Pos, 7)),
    {Rest1, Pos1, Exp} = expression(Rest0, Pos0, []),
    Include = add_line(#call{name = <<"require_once">>, args=[Exp]}, Pos),
    code(Rest1, Pos1, [Include|Parsed]);
code(<<S:8,T:8,A:8,T:8,I:8,C:8,SP:8,Rest/binary>>, Pos, Parsed) when
        ?OR(S,$S,$s) andalso ?OR(T,$T,$t) andalso ?OR(A,$A,$a) andalso
        ?OR(I,$I,$i) andalso ?OR(C,$C,$c) andalso
        (?IS_SPACE(SP) orelse ?IS_NEWLINE(SP)) ->
    NewPos = add_pos(Pos, 7),
    case expression(Rest, NewPos, []) of
        {Rest0, Pos0, #assign{variable=Var}=Assign} ->
            NewAssign = Assign#assign{variable = Var#variable{type = static}},
            code(Rest0, copy_level(Pos, Pos0), Parsed ++ [NewAssign]);
        {Rest0, Pos0, #variable{}=Var} ->
            NewVar = Var#variable{type = static},
            code(Rest0, copy_level(Pos, Pos0), Parsed ++ [NewVar])
    end;
code(<<A:8,_/binary>> = Rest, Pos, [#constant{}|_])
        when ?IS_ALPHA(A) orelse A =:= $_ ->
    throw_error(eparse, Pos, Rest);
code(<<A:8,_/binary>> = Rest, Pos, Parsed) when ?IS_ALPHA(A) orelse A =:= $_ ->
    {Rest0, Pos0, Parsed0} = expression(Rest,Pos,[]),
    code(Rest0, copy_level(Pos, Pos0), [Parsed0] ++ Parsed);
code(<<A:8,_/binary>> = Rest, Pos, Parsed) when ?IS_NUMBER(A)
                                           orelse A =:= $- orelse A =:= $(
                                           orelse A =:= $" orelse A =:= $'
                                           orelse A =:= $$ orelse A =:= $+
                                           orelse A =:= 126 orelse A =:= $! ->
    {Rest0, Pos0, Exp} = expression(Rest, Pos, []),
    code(Rest0, copy_level(Pos, Pos0), [Exp|Parsed]);
code(<<Space:8,Rest/binary>>, Pos, Parsed) when ?IS_SPACE(Space) ->
    code(Rest, add_pos(Pos,1), Parsed);
code(<<NewLine:8,Rest/binary>>, Pos, Parsed) when ?IS_NEWLINE(NewLine) ->
    code(Rest, new_line(Pos), Parsed);
code(<<";",Rest/binary>>, Pos, Parsed) ->
    code(Rest, add_pos(Pos,1), Parsed);
code(Text, Pos, _Parsed) ->
    throw_error(eparse, Pos, Text).

code_block(<<";",Rest/binary>>, {{_,abstract},_,_}=Pos, Parsed) ->
    {Rest, add_pos(Pos,1), Parsed};
code_block(<<"{",Rest/binary>>, Pos, Parsed) ->
    code(Rest, code_block_level(add_pos(Pos,1)), Parsed);
code_block(<<":",Rest/binary>>, {if_block,_,_}=Pos, Parsed) ->
    code(Rest, if_old_block_level(add_pos(Pos,1)), Parsed);
code_block(<<":",Rest/binary>>, {foreach_block,_,_}=Pos, Parsed) ->
    code(Rest, foreach_old_block_level(add_pos(Pos,1)), Parsed);
code_block(<<":",Rest/binary>>, {for_block,_,_}=Pos, Parsed) ->
    code(Rest, for_old_block_level(add_pos(Pos,1)), Parsed);
code_block(<<":",Rest/binary>>, {while_block,_,_}=Pos, Parsed) ->
    code(Rest, while_old_block_level(add_pos(Pos,1)), Parsed);
code_block(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_SPACE(SP) ->
    code_block(Rest, add_pos(Pos,1), Parsed);
code_block(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_NEWLINE(SP) ->
    code_block(Rest, new_line(Pos), Parsed);
code_block(<<>>, Pos, Parsed) ->
    {<<>>, Pos, Parsed};
code_block(Rest, Pos, Parsed) ->
    code(Rest, code_statement_level(Pos), Parsed).

variable(<<SP:8,Rest/binary>>, Pos, []) when ?IS_SPACE(SP) ->
    variable(Rest, add_pos(Pos,1), []);
variable(<<SP:8,Rest/binary>>, Pos, []) when ?IS_NEWLINE(SP) ->
    variable(Rest, new_line(Pos), []);
variable(<<"$",Rest/binary>>, Pos, []) ->
    variable(Rest, add_pos(Pos,1), []);
variable(<<A:8,Rest/binary>>, Pos, [])
        when ?IS_ALPHA(A) orelse A =:= $_ orelse A >= 16#7f ->
    Var = add_line(#variable{name = <<A:8>>}, Pos),
    variable(Rest, add_pos(Pos,1), [Var]);
variable(<<A:8,Rest/binary>>, {_,_,_}=Pos, [#variable{name=N}=V])
        when ?IS_NUMBER(A) orelse ?IS_ALPHA(A) orelse A =:= $_
        orelse A >= 16#7f ->
    variable(Rest, add_pos(Pos,1), [V#variable{name = <<N/binary,A:8>>}]);
variable(<<SP:8,Rest/binary>>, {enclosed,_,_}=Pos, Var) when ?IS_SPACE(SP) ->
    variable(Rest, add_pos(Pos,1), Var);
variable(<<SP:8,_/binary>> = Rest, {unclosed,_,_}=Pos, Var)
        when ?IS_SPACE(SP) ->
    {Rest, add_pos(Pos,1), Var};
variable(<<SP:8,Rest/binary>>, {enclosed,_,_}=Pos, Var) when ?IS_NEWLINE(SP) ->
    variable(Rest, new_line(Pos), Var);
variable(<<SP:8,_/binary>> = Rest, {unclosed,_,_}=Pos, Var)
        when ?IS_NEWLINE(SP) ->
    {Rest, new_line(Pos), Var};
variable(<<"}",Rest/binary>>, {enclosed,_,_}=Pos, Var) ->
    {Rest, add_pos(Pos,1), Var};
variable(<<"[",Rest/binary>>, Pos, [#variable{idx=Indexes}=Var]) ->
    {Rest1, Pos1, RawIdx} = expression(Rest, array_level(add_pos(Pos,1)), []),
    Idx = case RawIdx of
        [] -> auto;
        _ -> RawIdx
    end,
    variable(Rest1, copy_level(Pos, Pos1), [Var#variable{idx=Indexes ++ [Idx]}]);
variable(<<"->",Rest/binary>>, {L,_,_}=Pos, [#variable{}=Var])
        when is_number(L) ->
    % TODO move this code to ephp_parser_expr
    OpL = <<"->">>,
    Op = add_op({OpL, precedence(OpL), Pos}, add_op(Var, [])),
    {Rest0, Pos0, Exp} = expression(Rest, arg_level(add_pos(Pos,2)), Op),
    {Rest0, copy_level(Pos, Pos0), [Exp]};
variable(<<"->",Rest/binary>>, Pos, [#variable{}=Var]) ->
    % TODO move this code to ephp_parser_expr
    OpL = <<"->">>,
    Op = add_op({OpL, precedence(OpL), Pos}, add_op(Var, [])),
    {Rest0, Pos0, Exp} = expression(Rest, add_pos(Pos,2), Op),
    {Rest0, copy_level(Pos, Pos0), [Exp]};
variable(Rest, Pos, Parsed) ->
    {Rest, Pos, Parsed}.

constant(<<A:8,Rest/binary>>, Pos, []) when ?IS_ALPHA(A) orelse A =:= $_ ->
    constant(Rest, add_pos(Pos,1), [add_line(#constant{name = <<A:8>>},Pos)]);
constant(<<A:8,Rest/binary>>, Pos, [#constant{name=N}=C])
        when ?IS_ALPHA(A) orelse ?IS_NUMBER(A) orelse A =:= $_ ->
    constant(Rest, add_pos(Pos,1), [C#constant{name = <<N/binary, A:8>>}]);
constant(<<SP:8,_/binary>> = Rest, {unclosed,_,_}=Pos, [#constant{}]=Parsed)
        when ?IS_SPACE(SP) ->
    {Rest, Pos, Parsed};
constant(<<SP:8,Rest/binary>>, Pos, [#constant{}]=Parsed)
        when ?IS_SPACE(SP) ->
    constant_wait(Rest, add_pos(Pos,1), Parsed);
constant(<<SP:8,_/binary>> = Rest, {unclosed,_,_}=Pos, [#constant{}]=Parsed)
        when ?IS_NEWLINE(SP) ->
    {Rest, Pos, Parsed};
constant(<<SP:8,Rest/binary>>, Pos, [#constant{}]=Parsed)
        when ?IS_NEWLINE(SP) ->
    constant_wait(Rest, new_line(Pos), Parsed);
constant(<<"(",_/binary>> = Rest, Pos, Parsed) ->
    constant_wait(Rest, Pos, Parsed);
% TODO fail when unclosed is used?
constant(<<"::",_/binary>> = Rest, Pos, Parsed) ->
    constant_wait(Rest, Pos, Parsed);
constant(Rest, Pos, Parsed) ->
    {Rest, Pos, constant_known(Parsed, Pos)}.

%% if after one or several spaces there are a parens, it's a function
%% but if not, it should returns
constant_wait(<<"(",Rest/binary>>, Pos, [#constant{}=C]) ->
    Call = #call{name = C#constant.name, line = C#constant.line},
    ephp_parser_func:function(Rest, add_pos(Pos,1), [Call]);
constant_wait(<<"::$",Rest/binary>>, Pos, [#constant{}=C]) ->
    {Rest1, Pos1, [Var]} = variable(<<"$",Rest/binary>>, add_pos(Pos,2), []),
    NewVar = Var#variable{type=class, class=C#constant.name},
    {Rest2, Pos2, Exp} =
        expression(Rest1, copy_level(Pos, Pos1), add_op(NewVar, [])),
    {Rest2, Pos2, [Exp]};
constant_wait(<<"::",Rest/binary>>, Pos, [#constant{}=Cons]) ->
    case constant(Rest, add_pos(Pos,2), []) of
        {Rest1, Pos1, [#constant{name = <<"class">>}]} ->
            {Rest1, Pos1, [add_line(#text{text=Cons#constant.name}, Pos)]};
        {Rest1, Pos1, [#constant{}=C]} ->
            {Rest1, Pos1, [C#constant{type=class, class=Cons#constant.name}]};
        {Rest1, Pos1, [#call{}=C]} ->
            {Rest1, Pos1, [C#call{type=class, class=Cons#constant.name}]}
    end;
constant_wait(<<SP:8,Rest/binary>>, Pos, [#constant{}]=Parsed)
        when ?IS_SPACE(SP) ->
    constant_wait(Rest, add_pos(Pos,1), Parsed);
constant_wait(<<SP:8,Rest/binary>>, Pos, [#constant{}]=Parsed)
        when ?IS_NEWLINE(SP) ->
    constant_wait(Rest, new_line(Pos), Parsed);
constant_wait(Rest, Pos, Parsed) ->
    {Rest, Pos, constant_known(Parsed, Pos)}.

constant_known([#constant{name = <<"__LINE__">>}|Parsed], {_,R,_}=Pos) ->
    [add_line(#int{int=R}, Pos)|Parsed];
constant_known(C, _Pos) ->
    C.

st_global(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_SPACE(SP) ->
    st_global(Rest, add_pos(Pos,1), Parsed);
st_global(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_NEWLINE(SP) ->
    st_global(Rest, new_line(Pos), Parsed);
st_global(<<",",Rest/binary>>, Pos, Parsed) ->
    st_global(Rest, add_pos(Pos,1), Parsed);
st_global(<<";",Rest/binary>>, Pos, Parsed) ->
    Global = add_line(#global{vars = Parsed}, Pos),
    {Rest, add_pos(Pos,1), [Global]};
st_global(<<"$",_/binary>> = Rest, Pos, Parsed) ->
    {Rest0, Pos0, [Var]} = variable(Rest, Pos, []),
    st_global(Rest0, Pos0, [Var|Parsed]).

st_while(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_SPACE(SP) ->
    st_while(Rest, add_pos(Pos,1), Parsed);
st_while(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_NEWLINE(SP) ->
    st_while(Rest, new_line(Pos), Parsed);
st_while(<<"(",Rest/binary>>, Pos, Parsed) ->
    NewPos = add_pos(Pos,1),
    {<<")",Rest1/binary>>, Pos1, Conditions} =
        expression(Rest, arg_level(NewPos), []),
    {Rest2, Pos2, CodeBlock} = code_block(Rest1, while_block_level(Pos1), []),
    While = add_line(#while{
        type=pre,
        conditions=Conditions,
        loop_block=CodeBlock
    }, Pos),
    {Rest2, copy_level(Pos, Pos2), [While|Parsed]};
st_while(<<>>, Pos, _Parsed) ->
    throw_error(eparse, Pos, <<>>).

st_do_while(Rest, Pos, Parsed) ->
    case code_block(Rest, Pos, []) of
        {<<";",Rest0/binary>>, Pos0, CodeBlock} -> ok;
        {Rest0, Pos0, CodeBlock} -> ok
    end,
    {<<WhileRaw:5/binary,Rest1/binary>>, Pos1} = remove_spaces(Rest0, Pos0),
    <<"while">> = ephp_string:to_lower(WhileRaw),
    {Rest2, Pos2, [While]} = st_while(Rest1, Pos1, []),
    DoWhile = add_line(While#while{
        type=post,
        loop_block=CodeBlock
    }, Pos),
    {Rest2, copy_level(Pos, Pos2), [DoWhile|Parsed]}.

st_if(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_SPACE(SP) ->
    st_if(Rest, add_pos(Pos,1), Parsed);
st_if(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_NEWLINE(SP) ->
    st_if(Rest, new_line(Pos), Parsed);
st_if(<<"(",Rest/binary>>, Pos, Parsed) ->
    NewPos = add_pos(Pos,1),
    {<<")",Rest1/binary>>, Pos1, Conditions} =
        expression(Rest, arg_level(NewPos), []),
    {Rest2, Pos2, CodeBlock} = code_block(Rest1, if_block_level(Pos1), []),
    If = add_line(#if_block{
        conditions=Conditions,
        true_block=CodeBlock
    }, Pos),
    {Rest2, copy_level(Pos, Pos2), [If|Parsed]};
st_if(<<>>, Pos, _Parsed) ->
    throw_error(eparse, Pos, <<>>).

st_else(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_SPACE(SP) ->
    st_else(Rest, add_pos(Pos,1), Parsed);
st_else(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_NEWLINE(SP) ->
    st_else(Rest, new_line(Pos), Parsed);
st_else(Rest0, {Level,_,_}=Pos0, [#if_block{}=If|Parsed]) ->
    BlockPos = if_block_level(add_pos(Pos0,4)),
    {Rest1, {_,Row1,Col1}, CodeBlock} = code_block(Rest0, BlockPos, []),
    IfWithElse = If#if_block{false_block=CodeBlock},
    {Rest1, {Level,Row1,Col1}, [IfWithElse|Parsed]};
st_else(<<>>, Pos, _Parsed) ->
    throw_error(eparse, Pos, <<>>).

args(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_SPACE(SP) ->
    args(Rest, add_pos(Pos,1), Parsed);
args(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_NEWLINE(SP) ->
    args(Rest, new_line(Pos), Parsed);
args(Rest, Pos, Args) when Rest =/= <<>> ->
    case expression(Rest, arg_level(Pos), []) of
        {<<")",_/binary>> = Rest0, Pos0, Arg} ->
            {Rest0, add_pos(Pos0,1), Args ++ [Arg]};
        {<<";",_/binary>> = Rest0, Pos0, Arg} ->
            {Rest0, add_pos(Pos0,1), Args ++ [Arg]};
        {<<",", Rest0/binary>>, Pos0, Arg} ->
            args(Rest0, add_pos(Pos0, 1), Args ++ [Arg]);
        {Rest0, Pos0, Arg} ->
            args(Rest0, Pos0, Args ++ [Arg])
    end.

st_foreach(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_SPACE(SP) ->
    st_foreach(Rest, add_pos(Pos,1), Parsed);
st_foreach(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_NEWLINE(SP) ->
    st_foreach(Rest, new_line(Pos), Parsed);
st_foreach(<<"(",Rest/binary>>, Pos, Parsed) ->
    {Rest0, Pos0, Exp} = expression(Rest, foreach_block_level(Pos), []),
    {<<AS:2/binary,Rest1/binary>>, Pos1} = remove_spaces(Rest0, Pos0),
    <<"as">> = ephp_string:to_lower(AS),
    NewPos = array_def_level(add_pos(Pos1,2)),
    {<<")",Rest2/binary>>, Pos2, ExpIter} = expression(Rest1, NewPos, []),
    BlockPos = foreach_block_level(add_pos(Pos2,1)),
    {Rest3, Pos3, CodeBlock} = code_block(Rest2, BlockPos, []),
    RawFor = add_line(#foreach{
        iter=ExpIter,
        elements=Exp,
        loop_block=CodeBlock
    }, Pos),
    For = case ExpIter of
        #variable{} ->
            RawFor;
        [KIter,Iter] ->
            RawFor#foreach{kiter=KIter, iter=Iter}
    end,
    {Rest3, copy_level(Pos, Pos3), [For|Parsed]}.

switch_case_block([]) ->
    [];
switch_case_block(Blocks) ->
    {Block, [Switch|Rest]} = lists:splitwith(fun
        (#switch_case{}) -> false;
        (_) -> true
    end, Blocks),
    [Switch#switch_case{code_block=lists:reverse(Block)}|Rest].

st_switch(<<"(",Rest/binary>>, Pos, Parsed) ->
    {<<")", Rest0/binary>>, Pos0, Cond} = expression(Rest, add_pos(Pos,1), []),
    {<<"{", Rest1/binary>>, Pos1} = remove_spaces(Rest0, add_pos(Pos0, 1)),
    NewPos = switch_block_level(add_pos(Pos1, 1)),
    {Rest2, Pos2, CodeBlock} = code(Rest1, NewPos, []),
    Switch = add_line(#switch{
        condition=Cond,
        cases=CodeBlock
    }, Pos),
    {Rest2, copy_level(Pos, Pos2), [Switch|Parsed]}.

st_for(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_SPACE(SP) ->
    st_for(Rest, add_pos(Pos,1), Parsed);
st_for(<<SP:8,Rest/binary>>, Pos, Parsed) when ?IS_NEWLINE(SP) ->
    st_for(Rest, new_line(Pos), Parsed);
st_for(<<"(",Rest/binary>>, Pos, Parsed) ->
    {<<";",Rest0/binary>>, Pos0, Init} = args(Rest, add_pos(Pos,1), []),
    {<<";",Rest1/binary>>, Pos1, [Cond]} = args(Rest0, add_pos(Pos0,1), []),
    {<<")",Rest2/binary>>, Pos2, Upda} = args(Rest1, add_pos(Pos1,1), []),
    {Rest3, Pos3, CodeBlock} = code_block(Rest2,
                                          for_block_level(add_pos(Pos2,1)), []),
    For = add_line(#for{
        init=Init, conditions=Cond, update=Upda, loop_block=CodeBlock
    }, Pos),
    {Rest3, copy_level(Pos, Pos3), [For|Parsed]}.

comment_line(<<>>, Pos, Parsed) ->
    {<<>>, Pos, Parsed};
comment_line(<<"?>",_/binary>> = Rest, Pos, Parsed) ->
    {Rest, Pos, Parsed};
comment_line(<<"\n",Rest/binary>>, Pos, Parsed) ->
    {Rest, new_line(Pos), Parsed};
comment_line(<<_/utf8,Rest/binary>>, Pos, Parsed) ->
    comment_line(Rest, add_pos(Pos,1), Parsed).

comment_block(<<>>, Pos, _Parsed) ->
    %% TODO: throw parse error
    throw_error(eparse, Pos, missing_comment_end);
comment_block(<<"*/",Rest/binary>>, Pos, Parsed) ->
    {Rest, add_pos(Pos,2), Parsed};
comment_block(<<"\n",Rest/binary>>, Pos, Parsed) ->
    comment_block(Rest, new_line(Pos), Parsed);
comment_block(<<_/utf8,Rest/binary>>, Pos, Parsed) ->
    comment_block(Rest, add_pos(Pos,1), Parsed).

%%------------------------------------------------------------------------------
%% helper functions
%%------------------------------------------------------------------------------

add_to_text(L, _Pos, [#print_text{text=Text}=P|Parsed]) ->
    NewText = <<Text/binary, L/binary>>,
    [P#print_text{text=NewText}|Parsed];
add_to_text(L, Pos, Parsed) ->
    [add_line(#print_text{text=L}, Pos)|Parsed].

add_pos({Level,Row,Col}, Offset) ->
    {Level,Row,Col+Offset}.

new_line({Level,Row,_Col}) ->
    {Level,Row+1,1}.

if_old_block_level({_,Row,Col}) -> {if_old_block,Row,Col}.
for_old_block_level({_,Row,Col}) -> {for_old_block,Row,Col}.
foreach_old_block_level({_,Row,Col}) -> {foreach_old_block,Row,Col}.
while_old_block_level({_,Row,Col}) -> {while_old_block,Row,Col}.

if_block_level({_,Row,Col}) -> {if_block,Row,Col}.
for_block_level({_,Row,Col}) -> {for_block,Row,Col}.
foreach_block_level({_,Row,Col}) -> {foreach_block,Row,Col}.
while_block_level({_,Row,Col}) -> {while_block,Row,Col}.
switch_block_level({_,Row,Col}) -> {switch_block,Row,Col}.
switch_label_level({_,Row,Col}) -> {switch_label,Row,Col}.

normal_level({_,Row,Col}) -> {code,Row,Col}.
code_block_level({_,Row,Col}) -> {code_block,Row,Col}.
code_value_level({_,Row,Col}) -> {code_value,Row,Col}.
code_statement_level({_,Row,Col}) -> {code_statement,Row,Col}.
arg_level({_,Row,Col}) -> {arg,Row,Col}.
array_level({_,Row,Col}) -> {array,Row,Col}.
array_def_level({_,Row,Col}) -> {{array_def,0},Row,Col}.
literal_level({_,Row,Col}) -> {literal,Row,Col}.

add_line(true, _) -> true;
add_line(false, _) -> false;
add_line(#array{}=A, {_,Row,Col}) -> A#array{line={{line,Row},{column,Col}}};
add_line(#eval{}=E, {_,Row,Col}) -> E#eval{line={{line,Row},{column,Col}}};
add_line(#print{}=P, {_,Row,Col}) -> P#print{line={{line,Row},{column,Col}}};
add_line(#print_text{}=P, {_,Row,Col}) ->
    P#print_text{line={{line,Row},{column,Col}}};
add_line(#variable{}=V, {_,R,C}) -> V#variable{line={{line,R},{column,C}}};
add_line(#constant{}=O, {_,R,C}) -> O#constant{line={{line,R},{column,C}}};
add_line(#int{}=I, {_,R,C}) -> I#int{line={{line,R},{column,C}}};
add_line(#float{}=F, {_,R,C}) -> F#float{line={{line,R},{column,C}}};
add_line(#text_to_process{}=T, {_,R,C}) ->
    T#text_to_process{line={{line,R},{column,C}}};
add_line(#text{}=T, {_,R,C}) -> T#text{line={{line,R},{column,C}}};
add_line(#if_block{}=I, {_,R,C}) -> I#if_block{line={{line,R},{column,C}}};
add_line(#assign{}=A, {_,R,C}) -> A#assign{line={{line,R},{column,C}}};
add_line(#array_element{}=A, {_,R,C}) ->
    A#array_element{line={{line,R},{column,C}}};
add_line(#for{}=F, {_,R,C}) -> F#for{line={{line,R},{column,C}}};
add_line(#foreach{}=F, {_,R,C}) -> F#foreach{line={{line,R},{column,C}}};
add_line(#operation{}=O, {_,R,C}) -> O#operation{line={{line,R},{column,C}}};
add_line(#concat{}=O, {_,R,C}) -> O#concat{line={{line,R},{column,C}}};
add_line(#while{}=W, {_,R,C}) -> W#while{line={{line,R},{column,C}}};
add_line(#return{}=Rt, {_,R,C}) -> Rt#return{line={{line,R},{column,C}}};
add_line(#function{}=F, {_,R,C}) -> F#function{line={{line,R},{column,C}}};
add_line(#global{}=G, {_,R,C}) -> G#global{line={{line,R},{column,C}}};
add_line(#ref{}=Rf, {_,R,C}) -> Rf#ref{line={{line,R},{column,C}}};
add_line(#switch{}=S, {_,R,C}) -> S#switch{line={{line,R},{column,C}}};
add_line(#switch_case{}=S, {_,R,C}) -> S#switch_case{line={{line,R},{column,C}}};
add_line(#call{}=Cl, {_,R,C}) -> Cl#call{line={{line,R},{column,C}}};
add_line(#class{}=Cl, {_,R,C}) -> Cl#class{line={{line,R},{column,C}}};
add_line(#class_method{}=CM, {_,R,C}) ->
    CM#class_method{line={{line,R},{column,C}}};
add_line(#class_const{}=CC, {_,R,C}) ->
    CC#class_const{line={{line,R},{column,C}}};
add_line(#class_attr{}=CA, {_,R,C}) ->
    CA#class_attr{line={{line,R},{column,C}}};
add_line({object, Expr}, {_,R,C}) -> {object, Expr, {{line,R},{column,C}}};
add_line({class, Expr}, {_,R,C}) -> {class, Expr, {{line,R},{column,C}}};
add_line(#instance{}=I, {_,R,C}) -> I#instance{line={{line,R},{column,C}}};
add_line(#cast{}=Cs, {_,R,C}) -> Cs#cast{line={{line,R},{column,C}}}.

remove_spaces(<<SP:8,Rest/binary>>, Pos) when ?IS_SPACE(SP) ->
    remove_spaces(Rest, add_pos(Pos,1));
remove_spaces(<<SP:8,Rest/binary>>, Pos) when ?IS_NEWLINE(SP) ->
    remove_spaces(Rest, new_line(Pos));
remove_spaces(<<>>, Pos) -> {<<>>, Pos};
remove_spaces(Rest, Pos) -> {Rest, Pos}.

get_print({Type, Value, _}, Pos) when
        Type =:= int; Type =:= float; Type =:= text ->
    add_line(#print_text{text=ephp_data:to_bin(Value)}, Pos);
get_print(Value, Pos) when is_atom(Value) ->
    add_line(#print_text{text=ephp_data:to_bin(Value)}, Pos);
get_print(Expr, Pos) ->
    add_line(#print{expression=Expr}, Pos).

throw_error(Error, {_Level,Row,Col}, Data) ->
    Output = iolist_to_binary(Data),
    Size = min(byte_size(Output), 20),
    Index = {{line,Row},{column,Col}},
    ephp_error:error({error, Error, Index, ?E_PARSE,
        <<Output:Size/binary, "...">>}).
