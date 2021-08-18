# config/.credo.exs
%{
  configs: [
    %{
      name: "default",
      checks: [
        {Credo.Check.Readability.LargeNumbers, only_greater_than: 86400},
        {Credo.Check.Readability.ParenthesesOnZeroArityDefs, parens: true}
      ]
    }
  ]
}
