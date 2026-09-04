# Used by "mix format"
# Only DSL declarations omit parentheses. Reference calls keep them.
locals_without_parens = [
  flow: 1,
  step: 2,
  choice: 2,
  option: 2,
  otherwise: 1,
  map: 2,
  reduce: 2,
  iterate: 2,
  state: 2,
  dispatch: 2,
  output: 1,
  action: 1,
  params: 1,
  meta: 1,
  condition: 1,
  collection: 1,
  on_error: 1,
  initial: 1,
  update: 1,
  while: 1,
  repeat: 1,
  max_iterations: 1,
  decision: 1,
  expander: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
