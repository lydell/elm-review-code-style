module NoSimpleLetBody exposing (rule)

{-|

@docs rule

-}

import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.Range exposing (Location, Range)
import Review.Fix as Fix exposing (Fix)
import Review.Rule as Rule exposing (Rule)


{-| Reports when a let expression's body is a simple reference to a value declared in the let expression.

🔧 Running with `--fix` will automatically remove most of the reported errors.

    config =
        [ NoSimpleLetBody.rule
        ]

The reasoning is that it is not necessary to assign a name to the result of a let expression,
since they are redundant with the value or function containing the expression.

If it feels necessary to give a name anyway because it helps clarify the context, then it might be a sign that the computation of that value should be extracted to a function.

Let expressions will be reported regardless of whether they're at the root of a function or deeply nested.


## Fail

    a =
        let
            b =
                1

            c =
                b + 1
        in
        c


## Success

Anything that is not simply a reference to a value declared in the let expression is okay.

    a =
        let
            b =
                1
        in
        b + 1

The rule will not report when the referenced value was destructured in the let expression.

    first tuple =
        let
            ( value, _ ) =
                tuple
        in
        value


## When (not) to enable this rule

This rule resolves a minor style issue, and may not be worth enforcing depending on how strongly you feel about this issue.


## Try it out

You can try this rule out by running the following command:

```bash
elm-review --template jfmengels/elm-review-code-style/example --rules NoSimpleLetBody
```

-}
rule : Rule
rule =
    Rule.newModuleRuleSchemaUsingContextCreator "NoSimpleLetBody" initContext
        |> Rule.withExpressionEnterVisitor expressionVisitor
        |> Rule.fromModuleRuleSchema


type alias Context =
    { extractSourceCode : Range -> String
    }


initContext : Rule.ContextCreator () Context
initContext =
    Rule.initContextCreator
        (\extractSourceCode () -> { extractSourceCode = extractSourceCode })
        |> Rule.withSourceCodeExtractor


expressionVisitor : Node Expression -> Context -> ( List (Rule.Error {}), Context )
expressionVisitor node context =
    case Node.value node of
        Expression.LetExpression letBlock ->
            ( visitLetExpression context.extractSourceCode (Node.range node) letBlock, context )

        _ ->
            ( [], context )


visitLetExpression : (Range -> String) -> Range -> Expression.LetBlock -> List (Rule.Error {})
visitLetExpression extractSourceCode nodeRange { declarations, expression } =
    case Node.value expression of
        Expression.FunctionOrValue [] name ->
            let
                maybeResolution : Maybe Resolution
                maybeResolution =
                    findDeclarationToMove name declarations
            in
            case maybeResolution of
                Just resolution ->
                    [ Rule.errorWithFix
                        { message = "The referenced value should be inlined."
                        , details =
                            [ "The name of the value is redundant with the surrounding expression."
                            , "If you believe that the expression needs a name because it is too complex, consider splitting the expression up more or extracting it to a new function."
                            ]
                        }
                        (Node.range expression)
                        (fix extractSourceCode nodeRange (Node.range expression) resolution)
                    ]

                Nothing ->
                    []

        _ ->
            []


type Resolution
    = ReportNoFix
    | Move { toRemove : Range, toCopy : Range }
    | RemoveOnly { toCopy : Range }
    | MoveLast { previousEnd : Location, toCopy : Range }


findDeclarationToMove : String -> List (Node Expression.LetDeclaration) -> Maybe Resolution
findDeclarationToMove name declarations =
    findDeclarationToMoveHelp
        name
        (List.length declarations)
        declarations
        { index = 0
        , previousEnd = Nothing
        , lastEnd = Nothing
        }


findDeclarationToMoveHelp : String -> Int -> List (Node Expression.LetDeclaration) -> { index : Int, previousEnd : Maybe Location, lastEnd : Maybe Location } -> Maybe Resolution
findDeclarationToMoveHelp name nbOfDeclarations declarations { index, previousEnd, lastEnd } =
    case declarations of
        [] ->
            Nothing

        declaration :: rest ->
            case Node.value declaration of
                Expression.LetFunction function ->
                    let
                        functionDeclaration : Expression.FunctionImplementation
                        functionDeclaration =
                            Node.value function.declaration

                        functionName : String
                        functionName =
                            Node.value functionDeclaration.name
                    in
                    if functionName == name then
                        let
                            isLast : Bool
                            isLast =
                                index == nbOfDeclarations - 1
                        in
                        Just
                            (createResolution
                                { declaration = declaration, functionDeclaration = functionDeclaration }
                                { lastEnd = lastEnd, previousEnd = previousEnd }
                                isLast
                            )

                    else
                        findDeclarationToMoveHelp
                            name
                            nbOfDeclarations
                            rest
                            { index = index + 1
                            , previousEnd = lastEnd
                            , lastEnd = Just (Node.range declaration).end
                            }

                Expression.LetDestructuring _ _ ->
                    findDeclarationToMoveHelp
                        name
                        nbOfDeclarations
                        rest
                        { index = index + 1
                        , previousEnd = lastEnd
                        , lastEnd = Just (Node.range declaration).end
                        }


createResolution : { declaration : Node b, functionDeclaration : Expression.FunctionImplementation } -> { lastEnd : Maybe Location, previousEnd : Maybe Location } -> Bool -> Resolution
createResolution { declaration, functionDeclaration } { lastEnd, previousEnd } isLast =
    if not (List.isEmpty functionDeclaration.arguments) then
        ReportNoFix

    else
        case lastEnd of
            Just lastEnd_ ->
                if isLast then
                    MoveLast
                        { previousEnd = lastEnd_
                        , toCopy = Node.range functionDeclaration.expression
                        }

                else
                    Move
                        { toRemove =
                            { start = Maybe.withDefault (Node.range declaration).start previousEnd
                            , end = (Node.range declaration).end
                            }
                        , toCopy = Node.range functionDeclaration.expression
                        }

            Nothing ->
                if isLast then
                    RemoveOnly { toCopy = Node.range functionDeclaration.expression }

                else
                    Move
                        { toRemove =
                            { start = Maybe.withDefault (Node.range declaration).start previousEnd
                            , end = (Node.range declaration).end
                            }
                        , toCopy = Node.range functionDeclaration.expression
                        }


fix :
    (Range -> String)
    -> Range
    -> Range
    -> Resolution
    -> List Fix
fix extractSourceCode nodeRange letBodyRange resolution =
    case resolution of
        ReportNoFix ->
            []

        RemoveOnly { toCopy } ->
            -- Remove the let/in keywords and the let binding
            [ Fix.removeRange { start = nodeRange.start, end = toCopy.start }
            , Fix.removeRange { start = toCopy.end, end = nodeRange.end }
            ]

        Move { toRemove, toCopy } ->
            [ Fix.removeRange
                { start =
                    if nodeRange.start.row == toRemove.start.row then
                        toRemove.start

                    else
                        { row = toRemove.start.row, column = 1 }
                , end = toRemove.end
                }
            , Fix.replaceRangeBy
                letBodyRange
                (extractSourceCode toCopy)
            ]

        MoveLast { previousEnd, toCopy } ->
            let
                indentation : String
                indentation =
                    String.repeat (nodeRange.start.column - 1) " "
            in
            [ Fix.replaceRangeBy { start = previousEnd, end = toCopy.start } ("\n" ++ indentation ++ "in\n" ++ indentation)
            , Fix.removeRange { start = toCopy.end, end = nodeRange.end }
            ]
