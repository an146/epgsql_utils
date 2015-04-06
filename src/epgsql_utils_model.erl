%
% Basic model parse_transform

-module(epgsql_utils_model).
-export([parse_transform/2]).

-spec parse_transform(erl_syntax:syntaxTree(), term()) -> erl_syntax:syntaxTree().
parse_transform(AST, _Options) ->
    try
        {ModuleNameLine, ModuleName} = get_module_name(AST),
        RecordsMap = get_records_map(AST),
        RecordsInfo = get_records_info(AST, RecordsMap),

        Exports = lists:map(fun({Name, Arity}) -> compose_export(Name, Arity) end, [{struct_info, 1}]),
        Funcs = lists:map(fun(FunName) -> compose_fun(FunName, RecordsInfo, ModuleName) end, [struct_info, pack_record, unpack_record]),

        {Body, End} = lists:split(ModuleNameLine + 1, AST),
        AST1 = Body ++ Exports ++ End,
        {Head, Tail} = lists:split(length(AST1) - 1, AST1),
        Head ++ Funcs ++ Tail
    catch _T:E ->
        io:format("~s~n", [format_error("Parsing error: ~s", [E])]),
        exit(parsing_error)
    end.

-spec parse_record_fields([tuple()]) -> {[atom()], [{atom(), list()}]}.
parse_record_fields(RecordFields) ->
    lists:foldl(fun(F, {Keys, Types})->
            parse_record_fields_(F, {Keys, Types})
        end,
        {[], []},
        RecordFields
    ).

-spec parse_record_fields_(term(), {[atom()], [{atom(), list()}]}) -> {[atom()], [{atom(), list()}]}.
parse_record_fields_({record_field, _ ,{atom, _, FieldName}}, _Acc) ->
    error({untyped_model_field, FieldName});
parse_record_fields_({typed_record_field,
                 {record_field,_ , {atom,_ , FieldName}},
                 {type, _, union, [{atom, _, undefined}, Data]}}, {Keys, Types}) ->
    {Type, Params} = parse_field_type(Data) ,
    Keys1 = case is_key_type(Params) of
        true ->
            Keys ++ [FieldName];
        false ->
            Keys
    end,
    {Keys1, Types ++ [{FieldName, Type}]};
parse_record_fields_(_, Acc = {_, _}) ->
    Acc.

-spec parse_field_type(tuple()) -> {{atom(), atom()}, list()}.
parse_field_type({type,_ ,key, [Type]}) ->
    {T, _} = parse_field_type(Type),
    {T, [{key, true}]};
parse_field_type({type, _, list, [Type]}) ->
    {T, _} = parse_field_type(Type),
    {{epgsql_utils_orm, {list, T}}, []};
parse_field_type({type,_ ,Type,[]}) ->
    {{epgsql_utils_orm, Type}, []};
parse_field_type({remote_type, _ ,[{atom, _, M}, {atom, _, F}, []]}) ->
    {{M, F}, []};
parse_field_type(T) ->
    error(format_error("Unknown type ~p", [T])).

-spec is_key_type(list()) -> boolean().
is_key_type(Params) ->
    proplists:is_defined(key, Params).

-spec get_module_name(nonempty_maybe_improper_list()) -> atom().
get_module_name([]) ->
    error(format_error("No module name is declared", []));
get_module_name([{attribute, Line, module, Name}| _]) ->
    {Line, Name};
get_module_name([_|T]) ->
    get_module_name(T).

-spec get_records_map(list()) -> list().
get_records_map(AST) ->
    lists:foldl(fun(X, Acc) ->
            case X of
                {attribute, _, export_record_model, Map} -> Acc ++ Map;
                _ -> Acc
            end
        end,
        [],
        AST
    ).

-spec get_records_info(erl_syntax:syntaxTree(), list()) -> list().
get_records_info(AST, RecordsMap) ->
    RecordsInfo = lists:foldl(fun(H, Acc)->
            get_records_info_(H, Acc, RecordsMap)
        end,
        [],
        AST
    ),
    {LostRecords, _} = lists:unzip(lists:filter(fun({RecordName, _}) ->
            proplists:get_value(RecordName, RecordsInfo) == undefined
        end,
        RecordsMap
    )),
    case LostRecords of
        [] ->
            RecordsInfo;
        _ ->
            error(format_error("Undeclared records ~p", [LostRecords]))
    end.

-spec get_records_info_(tuple(), list(), list()) ->list().
get_records_info_({attribute, _ ,type, {{record, RecordName}, RecordFields, _}}, Acc, RecordMap) ->
    Table = proplists:get_value(table, proplists:get_value(RecordName, RecordMap, [])),
    case Table of
        %%Not a model record
        undefined ->
            Acc;
        _ ->
            {Keys, Types} = parse_record_fields(RecordFields),
            Acc ++ [{RecordName, {Keys, Types, Table}}]
    end;
get_records_info_(_, Acc, _RecordMap) ->
    Acc.

-spec compose_fun(atom(), list(), atom()) -> erl_syntax:syntaxTree().
compose_fun(Name = struct_info, RecordsInfo, _) ->
    Clauses = lists:foldl(fun({RecordName, {Keys, Types, Table}}, Acc) ->
            Acc ++ [
                erl_syntax:clause(
                    [erl_syntax:abstract({RecordName, table})],
                    [],
                    [
                        erl_syntax:block_expr([
                            erl_syntax:abstract(Table)
                        ])
                    ]
                ),
                erl_syntax:clause(
                    [erl_syntax:abstract({RecordName, keys})],
                    [],
                    [
                        erl_syntax:block_expr([
                            erl_syntax:abstract(Keys)
                        ])
                    ]
                ),
                erl_syntax:clause(
                    [erl_syntax:abstract({RecordName, fields})],
                    [],
                    [
                        erl_syntax:block_expr([
                            erl_syntax:abstract(Types)
                        ])
                    ]
                )
            ]
        end,
        [],
        RecordsInfo
    ),

    FullClauses = Clauses ++ [erl_syntax:clause(
        [erl_syntax:variable('T')],
        [],
        [
            erl_syntax:block_expr([
                erl_syntax:application(
                    erl_syntax:atom(erlang),
                    erl_syntax:atom(error),
                    [
                        erl_syntax:atom(badarg),
                        erl_syntax:list([erl_syntax:variable('T')])
                    ]
                )
            ])
        ]
    )],
    erl_syntax:revert(erl_syntax:function(
        erl_syntax:atom(Name),
        FullClauses
    ));

compose_fun(Name = pack_record, RecordsInfo, ModuleName) ->
    Clauses = lists:foldl(fun({RecordName, _}, Acc) ->
            Acc ++[
                erl_syntax:clause(
                    [
                        erl_syntax:tuple([erl_syntax:atom(RecordName), erl_syntax:variable('F')]),
                        erl_syntax:variable('V')
                    ],
                    [],
                    [
                        erl_syntax:block_expr([
                            erl_syntax:application(
                                erl_syntax:atom(epgsql_utils_orm),
                                erl_syntax:atom(pack_record_field),
                                [
                                    erl_syntax:tuple([
                                        erl_syntax:tuple([
                                            erl_syntax:atom(ModuleName),
                                            erl_syntax:atom(RecordName)
                                        ]),
                                        erl_syntax:variable('F')
                                    ]),
                                    erl_syntax:variable('V')
                                ]
                            )
                        ])
                    ]
                ),
                erl_syntax:clause(
                    [
                        erl_syntax:atom(RecordName),
                        erl_syntax:variable('V')
                    ],
                    [],
                    [
                        erl_syntax:block_expr([
                            erl_syntax:application(
                                erl_syntax:atom(epgsql_utils_orm),
                                erl_syntax:atom(pack_record),
                                [
                                    erl_syntax:tuple([
                                        erl_syntax:atom(ModuleName),
                                        erl_syntax:atom(RecordName)
                                    ]),
                                    erl_syntax:variable('V')
                                ]
                            )
                        ])
                    ]
                )
            ]
        end,
        [],
        RecordsInfo
    ),

    FullClauses = Clauses ++ [
        erl_syntax:clause(
            [
                erl_syntax:variable('T'),
                erl_syntax:variable('V')
            ],
            [],
            [
                erl_syntax:block_expr([
                    erl_syntax:application(
                        erl_syntax:atom(erlang),
                        erl_syntax:atom(error),
                        [
                            erl_syntax:atom(badarg),
                            erl_syntax:list([erl_syntax:variable('T'), erl_syntax:variable('V')])
                        ]
                    )
                ])
            ]
        )
    ],
    erl_syntax:revert(erl_syntax:function(
        erl_syntax:atom(Name),
        FullClauses
    ));
compose_fun(Name = unpack_record, RecordsInfo, ModuleName) ->
    Clauses = lists:foldl(fun({RecordName, _}, Acc) ->
            Acc ++[
                erl_syntax:clause(
                    [
                        erl_syntax:tuple([erl_syntax:atom(RecordName), erl_syntax:variable('F')]),
                        erl_syntax:variable('V')
                    ],
                    [],
                    [
                        erl_syntax:block_expr([
                            erl_syntax:application(
                                erl_syntax:atom(epgsql_utils_orm),
                                erl_syntax:atom(unpack_record_field),
                                [
                                    erl_syntax:tuple([
                                        erl_syntax:tuple([
                                            erl_syntax:atom(ModuleName),
                                            erl_syntax:atom(RecordName)
                                        ]),
                                        erl_syntax:variable('F')
                                    ]),
                                    erl_syntax:variable('V')
                                ]
                            )
                        ])
                    ]
                ),
                erl_syntax:clause(
                    [
                        erl_syntax:atom(RecordName),
                        erl_syntax:variable('V')
                    ],
                    [],
                    [
                        erl_syntax:block_expr([
                            erl_syntax:application(
                                erl_syntax:atom(epgsql_utils_orm),
                                erl_syntax:atom(unpack_record),
                                [
                                    erl_syntax:tuple([
                                        erl_syntax:atom(ModuleName),
                                        erl_syntax:atom(RecordName)
                                    ]),
                                    erl_syntax:variable('V')
                                ]
                            )
                        ])
                    ]
                )
            ]
        end,
        [],
        RecordsInfo
    ),

    FullClauses = Clauses ++ [
        erl_syntax:clause(
            [
                erl_syntax:variable('T'),
                erl_syntax:variable('V')
            ],
            [],
            [
                erl_syntax:block_expr([
                    erl_syntax:application(
                        erl_syntax:atom(erlang),
                        erl_syntax:atom(error),
                        [
                            erl_syntax:atom(badarg),
                            erl_syntax:list([erl_syntax:variable('T'), erl_syntax:variable('V')])
                        ]
                    )
                ])
            ]
        )
    ],
    erl_syntax:revert(erl_syntax:function(
        erl_syntax:atom(Name),
        FullClauses
    )).

-spec compose_export(atom(), non_neg_integer()) -> erl_syntax:syntaxTree().
compose_export(Name, Arity) ->
    erl_syntax:revert(erl_syntax:attribute(
        erl_syntax:atom(export),
        [
            erl_syntax:list([
                erl_syntax:arity_qualifier(erl_syntax:atom(Name), erl_syntax:integer(Arity))
            ])
        ]
    )).

format_error(Format, Args) ->
    iolist_to_binary(io_lib:format(Format, Args)).
