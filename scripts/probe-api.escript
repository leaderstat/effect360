main(_) ->
  io:format("mod path = ~p~n", [code:which(effectivnost_360_api)]),
  {Mod, Bin, Fname} = code:get_object_code(effectivnost_360_api),
  io:format("exports = ~p~n", [Mod:module_info(exports)]),
  ok.
