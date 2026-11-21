-- caw.luau, detached fron aw.luau on 08/09/2026
-- Parser and interpreter.
local caw = {}

export type Value =
    | LiteralValue
    | {
        read Type: "list",
        read Value: { Value },
      }
    | {
        read Type: "function",
        read Value:
            | {
                read IsLuau: true,
                read Function: ({ Value }) -> Value?,
              }
            | {
                read IsLuau: false,
                read Parameters: { string },
                read Variadic: boolean,
                read Body: { Expression },
              },
      }
    | {
        read Type: "tuple",
        read Value: { read Value },
      }

export type LiteralValue =
    | {
        read Type: "nil",
        read Value: nil,
      }
    | {
        read Type: "boolean",
        read Value: boolean,
      }
    | {
        read Type: "number",
        read Value: number,
      }
    | {
        read Type: "string",
        read Value: string,
      }

type Keyword = "nil" | "true" | "false" | "let" | "type" | "function" | "return" | "end" | "if" | "else" | "then"

local symbols = {
    ["("] = true,
    [")"] = true,
    ["{"] = true,
    ["}"] = true,
    ["["] = true,
    ["]"] = true,
    [","] = true,
    [":"] = true,
    ["|"] = true,
    ["&"] = true,
    ["->"] = true,
    ["~"] = true,
    ["..."] = true,
    ["#"] = true,
    ["^"] = true,
    ["+"] = true,
    ["-"] = true,
    ["*"] = true,
    ["/"] = true,
    ["//"] = true,
    [".."] = true,
    ["=="] = true,
    ["~="] = true,
    [">"] = true,
    [">="] = true,
    ["<"] = true,
    ["<="] = true,
    ["="] = true,
}

local operators = {
    ["+"] = true,
    ["-"] = true,
    ["*"] = true,
    ["/"] = true,
    ["//"] = true,
    [".."] = true,
    ["=="] = true,
    ["~="] = true,
    [">"] = true,
    [">="] = true,
    ["<"] = true,
    ["<="] = true,
    ["="] = true,
}

type KeywordToken = {
    read Type: "Keyword",
    read Keyword: Keyword,
}

type IdentifierToken = {
    read Type: "Identifier",
    read Identifier: string,
}

type LiteralToken = {
    read Type: "Literal",
    read Literal: LiteralValue,
}

type SymbolToken = {
    read Type: keyof<typeof(symbols)>,
}

type EndOfFileToken = {
    read Type: "EndOfFile",
}

type TokenData =
    | KeywordToken
    | IdentifierToken
    | LiteralToken
    | SymbolToken
    | EndOfFileToken

export type Position = { Line: number, Column: number, Offset: number }
type Token = TokenData & { Position: Position }

type ErroneousAnnotation = {
    read Kind: "Error",
}

-- `()` in function return annotations.
type UnitTypeAnnotation = {
    read Kind: "Unit",
}

type ReferenceAnnotation = {
    read Kind: "Reference",
    read Reference: string,
}

type SingletonTypeAnnotation = {
    read Kind: "Singleton",
    read Value: string | boolean,
}

type ListTypeAnnotation = {
    read Kind: "List",
    read Items: TypeAnnotation,
}

type GenericTypeAnnotation = {
    read Kind: "Generic",
    read Name: string,
}

type FunctionTypeAnnotation = {
    read Kind: "Function",
    read Generics: { read GenericTypeAnnotation },
    read Parameters: { read TypeAnnotation },
    read Returns: TypeAnnotation?,
}

type AliasInstantiationTypeAnnotation = {
    read Kind: "AliasInstantiation",
    read Name: string,
    read Arguments: { read TypeAnnotation },
}

type NegationTypeAnnotation = {
    read Kind: "Negation",
    read Negated: TypeAnnotation,
}

type UnionTypeAnnotation = {
    read Kind: "Union",
    read Components: { read TypeAnnotation },
}

type IntersectionTypeAnnotation = {
    read Kind: "Intersection",
    read Components: { read TypeAnnotation },
}

export type TypeAnnotation =
    | ErroneousAnnotation
    | UnitTypeAnnotation
    | ReferenceAnnotation
    | ListTypeAnnotation
    | SingletonTypeAnnotation
    | GenericTypeAnnotation
    | FunctionTypeAnnotation
    | AliasInstantiationTypeAnnotation
    | NegationTypeAnnotation
    | UnionTypeAnnotation
    | IntersectionTypeAnnotation

type FunctionParameter = {
    read Name: string,
    read Annotation: TypeAnnotation?,
}

type FunctionVariadicParameter = {
    read Present: boolean,
    read Annotation: TypeAnnotation?,
}

type ExpressionData =
    | {
        read Type: "Declaration",
        read Declaration: {
            read Name: string,
            read Value: Expression?,
            read Annotation: TypeAnnotation?,
        },
      }
    | {
        read Type: "Constant",
        read Constant: LiteralValue,
      }
    | {
        read Type: "Reference",
        read Reference: string,
      }
    | {
        read Type: "Call",
        read Call: {
            read Identifier: string,
            read Arguments: { read Expression },
        },
      }
    | {
        read Type: "BinaryOperation",
        read Operator: keyof<typeof(operators)>,
        read Left: Expression,
        read Right: Expression,
      }
    | {
        read Type: "UnaryOperation",
        read Operator: "-" | "#",
        read Operand: Expression,
      }
    | {
        read Type: "ReadIndex",
        read List: Expression,
        read Index: Expression,
      }
    | {
        read Type: "WriteIndex",
        read List: Expression,
        read Index: Expression,
        read Value: Expression,
      }
    | {
        read Type: "Function",
        read Function: {
            read Name: string?,
            read Generics: { read GenericTypeAnnotation },
            read Parameters: { read FunctionParameter },
            read Variadic: FunctionVariadicParameter,
            read ReturnAnnotation: TypeAnnotation?,
            read Body: { Expression },
        },
      }
    | {
        read Type: "Return",
        read Return: Expression?,
      }
    | {
        read Type: "List",
        read List: { read Expression },
      }
    | {
        read Type: "VariadicArguments",
      }
    | {
        read Type: "VariadicSelection",
        read Selection: Expression,
      }
    | {
        read Type: "VariadicLength",
      }
    | {
        read Type: "IfCondition",
        read Condition: Expression,
        read IfBody: { read Expression },
        read ElseBody: { read Expression }?,
      }
    | {
        read Type: "TypeAliasDeclaration",
        read Name: string,
        read Generics: { read TypeAnnotation },
        read Value: TypeAnnotation,
      }
    | {
        read Type: "InvalidSyntax",
        read Token: string,
      }

export type Expression = ExpressionData & { Position: Position }

export type ParseResult = { read Success: boolean, read Expressions: { read Expression } }

local keywords: { read [string]: Keyword? } = {
    ["nil"] = "nil",
    ["true"] = "true",
    ["false"] = "false",
    let = "let",
    type = "type",
    ["function"] = "function",
    ["return"] = "return",
    ["if"] = "if",
    ["else"] = "else",
    ["then"] = "then",
    ["end"] = "end",
}

local function unreachable(x: never): never
    error(`Unexpected branch with value '{ x }' ({ typeof(x) }), this is an internal error.`)
end

local function nextCharacter(str: string, position: number): (string, number)
    if position > #str then
        return "", position + 1
    end

    local c = string.sub(str, position, position)
    position += 1

    while not utf8.len(c) or utf8.len(c) == 0 and position < #str do
        c ..= string.sub(str, position, position)
        position += 1
    end

    return c, position
end

local function isWhitespace(c: string)
    return c == " " or c == "\t" or c == "\r" or c == "\n"
end

local function isEof(c: string)
    return c == ""
end

local function isSeparator(c: string)
    return isEof(c) or isWhitespace(c) or c == ";" or c == '"' or symbols[c]
end

local function nextToken(state: ParseState): Token
    local token = ""
    local c

    repeat
        c, state.Position.Offset = nextCharacter(state.Program, state.Position.Offset)
        state.Position.Column += 1

        if c == "\n" then
            state.Position.Line += 1
            state.Position.Column = 1
        end
    until not isWhitespace(c)

    state.Position.Column += 1
    local start = table.clone(state.Position)

    local function tk(t: TokenData): Token
        local tok: Token = t :: Token
        tok.Position = start

        return tok
    end

    if isSeparator(c) then
        local next, pos = nextCharacter(state.Program, state.Position.Offset)

        if next == "=" or (next == "-" and c == "-")
            or next == ">" and c == "-"
        then
            token = c .. next
            state.Position.Offset = pos
        else
            token = c
        end

        if token == "--" then
            repeat
                next, pos = nextCharacter(state.Program, state.Position.Offset)
                state.Position.Offset = pos
            until next == "\n" or isEof(next)

            state.Position.Column = 1
            state.Position.Line += 1
            return nextToken(state)
        end
    else
        local before = state.Position.Offset

        repeat
            token ..= c
            before = state.Position.Offset
            c, state.Position.Offset = nextCharacter(state.Program, state.Position.Offset)
        until isSeparator(c) or (tonumber(token) and not tonumber(c) and c ~= ".")

        state.Position.Offset = before
    end

    if tonumber((nextCharacter(token, 1))) then
        local literal = tonumber(token)

        if not literal then
            error(`Invalid identifier '{ token }'.`)
        end

        return tk{
            Type = "Literal",
            Literal = {
                Type = "number" :: "number", -- TODO luau cast
                Value = literal,
            },
        }
    elseif token == '"' then
        local strlit = ""
        local nextC = ""
        nextC, state.Position.Offset = nextCharacter(state.Program, state.Position.Offset)

        while nextC ~= '"' do
            if isEof(nextC) then
                state.Report("Incomplete string", state)
                return tk{
                    Type = "EndOfFile",
                }
            end

            strlit ..= nextC
            nextC, state.Position.Offset = nextCharacter(state.Program, state.Position.Offset)
        end

        return tk{
            Type = "Literal",
            Literal = {
                Type = "string" :: "string",
                Value = strlit,
            },
        }
    elseif symbols[token] then -- TODO luau cast (also not accurate)
        return tk{
            Type = token :: keyof<typeof(symbols)>
        }
    elseif string.match(nextCharacter(token, 1), "%a") or (string.byte(nextCharacter(token, 1)) and string.byte(nextCharacter(token, 1)) > 127) then
        if keywords[token] then
            return tk{
                Type = "Keyword",
                Keyword = token :: Keyword,
            }
        else
            return tk{
                Type = "Identifier",
                Identifier = token,
            }
        end
    end

    if #token > 0 then
        state.Report(`Invalid syntax '{ token }'`, state)
    end

    return tk{
        Type = "EndOfFile",
    }
end

local function peekNextToken(state: ParseState): (Token, () -> ())
    local peekState = table.clone(state)
    peekState.Position = table.clone(peekState.Position)

    return nextToken(peekState), function()
        state.Position = peekState.Position
    end
end

local function tokenToString(tk: Token): string
    if tk.Type == "Keyword" then
        return tk.Keyword
    elseif tk.Type == "Identifier" then
        return tk.Identifier
    elseif tk.Type == "Literal" then
        return tostring(tk.Literal.Value)
    else
        return tk.Type
    end
end

local function consumeOptionalComma(state: ParseState)
    local next, consume = peekNextToken(state)

    if next.Type == "," then
        consume()
    end
end

type ParseState = {
    Program: string,
    Position: Position,
    FunctionDepth: number,
    Report: (string, { Position: Position }) -> (),
}

local function ex(expr: ExpressionData, t: { Position: Position }): Expression
    local x: Expression = expr :: Expression
    x.Position = table.clone(t.Position)

    return x
end

local function invalidExpr(state, msg): Expression
    local withPos = { Position = table.clone(state.Position) }
    state.Report(msg, withPos)

    return ex({
        Type = "InvalidSyntax",
        Token = msg,
    }, withPos)
end

local parseTypeAnnotation
local maybeCombineWithTypeOperator

local function parseBinaryTypeOperator(state: ParseState, left: TypeAnnotation, opTk: Token): TypeAnnotation
    local combined: TypeAnnotation = {
        -- TODO luau false positive type error when this is `"Union" | "Intersection"`
        Kind = if opTk.Type == "|" then "Union" else "Intersection" :: "Union",
        Components = { left, parseTypeAnnotation(state) },
    }

    return maybeCombineWithTypeOperator(state, combined)
end

function maybeCombineWithTypeOperator(state: ParseState, left: TypeAnnotation): TypeAnnotation
    local maybeOperator, consumeOperator = peekNextToken(state)

    if maybeOperator.Type == "|" or maybeOperator.Type == "&" then
        consumeOperator()
        -- TODO luau type error on `maybeOperator`
        return parseBinaryTypeOperator(state, left, maybeOperator)
    else
        return left
    end
end

local function parseGenericParameterList(state: ParseState): { read GenericTypeAnnotation }
    local maybeCloser, consumeCloser = peekNextToken(state)
    local gens = {}

    while maybeCloser.Type ~= ">" do
        local gen = nextToken(state)

        if gen.Type ~= "Identifier" then
            state.Report(`Expected generic name, got '{ tokenToString(gen) }' instead.`, gen)
            break
        end

        table.insert(gens, { Kind = "Generic", Name = gen.Identifier })

        consumeOptionalComma(state)
        maybeCloser, consumeCloser = peekNextToken(state)
    end

    consumeCloser()
    return gens
end

function parseTypeAnnotation(state: ParseState, shallow: boolean?): TypeAnnotation
    local annotation = nextToken(state)
    local ty: TypeAnnotation? = nil

    if annotation.Type == "Identifier" then
        local maybeInstantiation, consumeOpenInstantion = peekNextToken(state)

        if maybeInstantiation.Type == "<" then
            consumeOpenInstantion()

            local closeInstantiation, consumeCloseInstantiation = peekNextToken(state)
            local typeArguments: { TypeAnnotation } = {}

            while closeInstantiation.Type ~= ">" and closeInstantiation.Type ~= "EndOfFile" do
                table.insert(typeArguments, parseTypeAnnotation(state))

                consumeOptionalComma(state)
                closeInstantiation, consumeCloseInstantiation = peekNextToken(state)
            end

            consumeCloseInstantiation()

            ty = {
                Kind = "AliasInstantiation",
                Name = annotation.Identifier,
                Arguments = typeArguments,
            }
        else
            ty = {
                Kind = "Reference",
                Reference = annotation.Identifier,
            }
        end
    elseif annotation.Type == "Keyword" then
        if annotation.Keyword == "nil" then
            ty = {
                -- TODO luau cast
                Kind = "Reference" :: "Reference",
                Reference = "nil",
            }
        elseif annotation.Keyword == "true" or annotation.Keyword == "false" then
            ty = {
                Kind = "Singleton",
                Value = annotation.Keyword == "true",
            }
        else
            state.Report(`Invalid annotation keyword '{ annotation.Keyword }'.`, annotation)
        end
    elseif annotation.Type == "Literal" then
        if annotation.Literal.Type == "string" or annotation.Literal.Type == "boolean" then
            ty = {
                Kind = "Singleton",
                Value = annotation.Literal.Value,
            }
        else
            state.Report(`{ annotation.Literal.Type } singletons are not supported.`, annotation)
        end
    elseif annotation.Type == "~" then
        ty = {
            Kind = "Negation",
            Negated = parseTypeAnnotation(state, true),
        }
    elseif annotation.Type == "<" then
        local gens = parseGenericParameterList(state)
        local next = peekNextToken(state)
        local func = parseTypeAnnotation(state)

        if func.Kind == "Function" then
            ty = {
                Kind = "Function",
                Generics = gens,
                Parameters = func.Parameters,
                Returns = func.Returns,
            }
        else
           state.Report(`Expected function type to follow generic parameter list, got { func.Kind } instead.`, next)
        end

    elseif annotation.Type == "(" then
        local params = {}
        local definitelyFunction = false
        local parens, consumeParens = peekNextToken(state)

        while parens.Type ~= ")" do
            if parens.Type == "EndOfFile" or parens.Type == "=" then
                state.Report(`Expected ')', got '{ tokenToString(parens) }' instead.`, parens)
                return { Kind = "Error" }
            end

            table.insert(params, parseTypeAnnotation(state))
            parens, consumeParens = peekNextToken(state)

            if parens.Type == "," then
                definitelyFunction = true
                consumeParens()
                parens, consumeParens = peekNextToken(state)
            end
        end

        consumeParens()
        local maybeArrow, consumeArrow = peekNextToken(state)

        if maybeArrow.Type == "->" then
            consumeArrow()

            local returns = parseTypeAnnotation(state)

            if returns.Kind == "Unit" then
                returns = nil
            end

            ty = {
                Kind = "Function",
                Generics = {},
                Parameters = params,
                Returns = returns,
            }
        -- `(T, U)` is not a valid annotation,
        elseif definitelyFunction then
            state.Report(`Expected '->' for function type, got '{ tokenToString(maybeArrow) }' instead.`, maybeArrow)
        -- ... but `(T)` is.
        else
            ty = params[1] or { Kind = "Unit" :: "Unit" }
        end
    elseif annotation.Type == "{" then
        local itemTy = parseTypeAnnotation(state)
        local closeCurly = nextToken(state)

        if closeCurly.Type ~= "}" then
            state.Report(`Expected '}', got '{ tokenToString(closeCurly) }'.`, closeCurly)
        end

        ty = {
            Kind = "List",
            Items = itemTy,
        }
    else
        state.Report(`Expected annotation, got '{ tokenToString(annotation) }'.`, annotation)
    end

    if shallow then
        return ty or { Kind = "Error" }
    else
        return maybeCombineWithTypeOperator(state, ty or { Kind = "Error" :: "Error" })
    end
end

local function maybeParseTypeAnnotation(state: ParseState): TypeAnnotation?
    local maybeColon, consumeColon = peekNextToken(state)

    if maybeColon.Type == ":" then
        consumeColon()
        return parseTypeAnnotation(state)
    end

    return nil
end

local parseExpression

local function parseBody(state: ParseState, stopAtElse: boolean?): ({ Expression }, Token)
    local body: { Expression } = {}
    local endTk, consumeEnd = peekNextToken(state)

    while endTk.Type ~= "Keyword" or (endTk.Keyword ~= "end" and (not stopAtElse or endTk.Keyword ~= "else")) do
        if endTk.Type == "EndOfFile" then
            state.Report(`Unexpected end-of-file before function 'end'.`, endTk)
            break
        end

        local expr = parseExpression(state)
        if not expr then
            break
        end

        table.insert(body, expr)
        endTk, consumeEnd = peekNextToken(state)
    end

    consumeEnd()
    return body, endTk
end

local function getOperatorPrecedence(operatorTk: SymbolToken)
    local precedences: { [string]: number? } = {
        ["="] = 1,
        [".."] = 1,
        ["+"] = 1,
        ["-"] = 1,
        ["*"] = 2,
        ["/"] = 2,
        ["//"] = 2,
    }

    return precedences[operatorTk.Type] or 0
end

local maybeCombineWithBinaryOperation

local function parseBinaryOperation(state: ParseState, left: Expression, opTk: SymbolToken, prevPrecedence: number?): Expression
    if opTk.Type == "=" and left.Type ~= "Reference" then
        state.Report(`Mutation operator expects LHS to be a reference, got a { left.Type } instead.`, left)
    end

    local precedence = getOperatorPrecedence(opTk)

    local op = ex({
        Type = "BinaryOperation",
        Operator = opTk.Type,
        Left = left,
        Right = parseExpression(state, precedence + 1) or invalidExpr(state, `Got end-of-file trying to parse '{ opTk.Type }' expression.`),
    }, left)

    return maybeCombineWithBinaryOperation(state, op, prevPrecedence)
end

function maybeCombineWithBinaryOperation(state: ParseState, left: Expression, precedence: number?)
    if precedence == math.huge then
        return left
    end

    local maybeOperator, consumeOperator = peekNextToken(state)

    if operators[maybeOperator.Type] and getOperatorPrecedence(maybeOperator) >= (precedence or 0) then
        consumeOperator()
        return parseBinaryOperation(state, left, maybeOperator, precedence)
    else
        return left
    end
end

local function parseFunction(state: ParseState, token: Token): Expression
    local gens = {}
    local name = nil
    local openParenTk = nextToken(state)

    if openParenTk.Type == "Identifier" then
        name = openParenTk.Identifier
        openParenTk = nextToken(state)
    end

    if openParenTk.Type == "<" then
        gens = parseGenericParameterList(state)
        openParenTk = nextToken(state)
    end

    if openParenTk.Type ~= "(" then
        return invalidExpr(state, `Expected opening parentheses after function prefix, got '{ tokenToString(openParenTk) }'.`)
    end

    local parameters = {}
    local paramsPresent = {}
    local variadic: FunctionVariadicParameter = {
        Present = false,
    }
    local paramTk = nextToken(state)

    while paramTk.Type ~= ")" do
        if paramTk.Type == "Identifier" then
            if paramsPresent[paramTk.Identifier] then
                state.Report(`Duplicate parameter '{ paramTk.Identifier }'.`, paramTk)
            end

            table.insert(parameters, {
                Name = paramTk.Identifier,
                Annotation = maybeParseTypeAnnotation(state),
            })
            paramsPresent[paramTk.Identifier] = true

            consumeOptionalComma(state)
            paramTk = nextToken(state)
        elseif paramTk.Type == "..." then
            variadic = {
                Present = true,
                Annotation = maybeParseTypeAnnotation(state),
            }

            local closeParen = nextToken(state)

            if closeParen.Type ~= ")" then
                return invalidExpr(state, `Expected closing parentheses after ellipsis in function parameter list, got '{ tokenToString(closeParen) }' instead.`)
            end

            break
        else
            state.Report(`Expected function parameter name, got '{ tokenToString(paramTk) }'.`, paramTk)
            break
        end
    end

    local returnTypeAnnotation = nil
    local maybeColon, consumeColon = peekNextToken(state)

    if maybeColon.Type == ":" then
        consumeColon()
        returnTypeAnnotation = parseTypeAnnotation(state)
    end

    state.FunctionDepth += 1

    local body = parseBody(state)

    state.FunctionDepth -= 1

    return ex({
        Type = "Function",
        Function = {
            Name = name,
            Generics = gens,
            Parameters = parameters,
            Variadic = variadic,
            ReturnAnnotation = returnTypeAnnotation,
            Body = body,
        },
    }, token)
end

function parseExpression(state: ParseState, precedence: number?): Expression?
    local token = nextToken(state)

    if token.Type == "Keyword" then
        if token.Keyword == "let" then
            local nameTk = nextToken(state)
            local name = "*error*"
            local annotation = nil

            if nameTk.Type == "Identifier" then
                name = nameTk.Identifier
                annotation = maybeParseTypeAnnotation(state)
            else
                state.Report(`Expected an identifier, got '{ tokenToString(nameTk) }'.`, nameTk)

                return ex({
                    Type = "InvalidSyntax",
                    Token = nameTk.Type,
                }, nameTk)
            end

            local value = nil
            local maybeEqualsTk, consumeEquals = peekNextToken(state)

            if maybeEqualsTk.Type == "=" then
                consumeEquals()
                value = parseExpression(state) or invalidExpr(state, `Got end-of-file trying to parse declaration.`)
            end

            return ex({
                Type = "Declaration",
                Declaration = {
                    Name = name,
                    Value = value,
                    Annotation = annotation,
                },
            }, token)
        elseif token.Keyword == "type" then
            local name = nextToken(state)

            if name.Type ~= "Identifier" then
                return invalidExpr(state, `Expected identifier after 'type', got '{ tokenToString(name) }' instead.`)
            end

            local generics: { read GenericTypeAnnotation } = {}
            local equalsOrGenericList = nextToken(state)

            if equalsOrGenericList.Type == "<" then
                generics = parseGenericParameterList(state)

                local equals = nextToken(state)

                if equals.Type ~= "=" then
                    invalidExpr(state, `Expected '=' after generic parameter list, got '{ tokenToString(equals) }' instead.`)
                end
            elseif equalsOrGenericList.Type ~= "=" then
                return invalidExpr(state, `Expected '=' or '<' after type alias name, got '{ tokenToString(equalsOrGenericList) }' instead.`)
            end

            return ex({
                Type = "TypeAliasDeclaration",
                Name = name.Identifier,
                Generics = generics,
                Value = parseTypeAnnotation(state),
            }, token)
        elseif token.Keyword == "nil" then
            return ex({
                Type = "Constant",
                Constant = { Type = "nil" },
            }, token)
        elseif token.Keyword == "true" or token.Keyword == "false" then
            return ex({
                Type = "Constant",
                Constant = { Type = "boolean", Value = token.Keyword == "true" }
            }, token)
        elseif token.Keyword == "function" then
            return parseFunction(state, token)
        elseif token.Keyword == "return" then
            if state.FunctionDepth == 0 then
                return invalidExpr(state, "Cannot 'return' outside of functions.")
            else
                -- TODO not consuming it?
                local nextTk, _ = peekNextToken(state)
                local expr = if nextTk.Type == "Keyword" and nextTk.Keyword == "end" then nil else parseExpression(state)

                return ex({
                    Type = "Return",
                    Return = expr,
                }, token)
            end
        elseif token.Keyword == "end" then
            state.Report(`Unexpected 'end'.`, token)

            return ex({
                Type = "InvalidSyntax",
                Token = token.Keyword,
            }, token)
        elseif token.Keyword == "if" then
            local condition = parseExpression(state) or invalidExpr(state, "Reached end-of-file trying to parse 'if' condition.")
            local thenTk = nextToken(state)

            if thenTk.Type ~= "Keyword" or thenTk.Keyword ~= "then" then
                return invalidExpr(state, `Expected 'then' keyword following condition, got '{ tokenToString(thenTk) }'.`)
            end

            local ifBody, endTk = parseBody(state, true)
            local elseBody = nil

            if endTk.Type == "Keyword" and endTk.Keyword == "else" then
                elseBody = parseBody(state)
            end

            return ex({
                Type = "IfCondition",
                Condition = condition,
                IfBody = ifBody,
                ElseBody = elseBody,
            }, token)
        elseif token.Keyword == "then" or token.Keyword == "else" then
            return invalidExpr(state, `Unexpected '{ token.Keyword }' keyword.`)
        else
            unreachable(token.Keyword)
            error(`Unreachable.`)
        end
    elseif token.Type == "Identifier" then
        local left: Expression
        local maybeParenthesesTk, consumeParentheses = peekNextToken(state)

        if maybeParenthesesTk.Type == "(" then
            consumeParentheses()

            local argC = nextCharacter(state.Program, state.Position.Offset)
            local args = {}

            while argC ~= ")" do
                local arg = parseExpression(state)
                if not arg then
                    return invalidExpr(state, `Got end-of-file trying to parse function argument.`)
                end

                table.insert(args, arg)
                argC = nextCharacter(state.Program, state.Position.Offset)
            end

            state.Position.Offset += 1 -- skip parens

            left = ex({
                Type = "Call",
                Call = {
                    Identifier = token.Identifier,
                    Arguments = args,
                },
            }, token)
        else
            left = ex({
                Type = "Reference",
                Reference = token.Identifier,
            }, token)
        end

        local maybeSquareBracketTk, consumeSquareBracket = peekNextToken(state)

        if maybeSquareBracketTk.Type == "[" then
            consumeSquareBracket()

            local index = parseExpression(state) or invalidExpr(state, `Reached end-of-file trying to parse index expression.`)
            local closeBrackets = nextToken(state)

            if closeBrackets.Type ~= "]" then
                return invalidExpr(state, `Expected closing square brackets, got end-of-file.`)
            end

            local maybeEqualsTk, consumeEquals = peekNextToken(state)

            if maybeEqualsTk.Type == "=" then
                consumeEquals()

                local value = parseExpression(state) or invalidExpr(state, `Reached end-of-file trying to parse index assignment.`)
                return ex({
                    Type = "WriteIndex",
                    List = left,
                    Index = index,
                    Value = value,
                }, token)
            else
                left = ex({
                    Type = "ReadIndex",
                    List = left,
                    Index = index,
                }, token)
            end
        end

        return maybeCombineWithBinaryOperation(state, left, precedence)
    elseif token.Type == "Literal" then
        -- TODO luau does not report error when `position` is not attached even though the annotation is explicit
        local constant: Expression = ex({
            Type = "Constant",
            Constant = token.Literal,
        }, token)

        return maybeCombineWithBinaryOperation(state, constant, precedence)
    elseif token.Type == "," then
        -- TODO check
        state.Position.Offset += 1
        return parseExpression(state)
    elseif operators[token.Type] then
        if token.Type == "-" or token.Type == "#" then
            local inner: Expression

            local nextTk, consumeNext = peekNextToken(state)

            if nextTk.Type == "(" then
                consumeNext()

                inner = parseExpression(state) or invalidExpr(state, `Got end-of-file parsing '{ tokenToString(token) }' expression after parentheses.`)
                state.Position.Offset += 1 -- skip closing parens
                state.Position.Column += 1
            elseif nextTk.Type == "..." then
                if token.Type == "#" then
                    consumeNext()

                    return ex({
                        Type = "VariadicLength",
                    }, token)
                end
            else
                inner = parseExpression(state, math.huge) or invalidExpr(state, `Got end-of-file parsing '{ tokenToString(token) }' expression.`)
            end

            local negation = ex({
                Type = "UnaryOperation",
                Operator = token.Type,
                Operand = inner,
            }, token)

            return maybeCombineWithBinaryOperation(state, negation)
        else
            state.Report(`Unexpected '{ token.Type }' operator.`, token)

            return ex({
                Type = "InvalidSyntax",
                Token = token.Type,
            }, token)
        end
    elseif token.Type == "{" then
        local items: { Expression } = {}
        local itemTk, consumeClosingParentheses = peekNextToken(state)

        while itemTk.Type ~= "}" do
            local item = parseExpression(state)

            if item then
                table.insert(items, item)
            else
                return invalidExpr(state, `Reached end-of-file parsing list items.`)
            end

            consumeOptionalComma(state)
            itemTk, consumeClosingParentheses = peekNextToken(state)
        end

        consumeClosingParentheses()

        return ex({
            Type = "List",
            List = items,
        }, token)

    elseif token.Type == "..." then
        local selectorTk, consumeSelector = peekNextToken(state)

        if selectorTk.Type == "[" then
            consumeSelector()

            local selector = parseExpression(state) or invalidExpr(state, `Reached end-of-file parsing variadic argument selector.`)
            local closingTk = nextToken(state)

            if closingTk.Type ~= "]" then
                state.Report(`Expected closing square brackets for variadic argument selector, got '{ tokenToString(closingTk) }' instead.`, closingTk)
            end

            return maybeCombineWithBinaryOperation(state, ex({
                Type = "VariadicSelection",
                Selection = selector,
            }, token), precedence)
        else
            return ex({
                Type = "VariadicArguments",
            }, token)
        end
    elseif token.Type == "(" then
        local inner = parseExpression(state)
        local parentheses = nextToken(state)
        assert(parentheses.Type == ")", `Expected closing parentheses, got '{ tokenToString(parentheses) }'`)

        return inner

    elseif token.Type == "EndOfFile" then
        return nil
    else
        state.Report(`Unexpected '{ tokenToString(token) }'.`, token)

        return ex({
            Type = "InvalidSyntax",
            Token = token.Type,
        }, token)
    end
end

function caw.parse(program: string): ParseResult
    local success = true

    local state: ParseState = {
        Program = program,
        Position = {
            Line = 1,
            Column = 1,
            Offset = 1,
        },
        FunctionDepth = 0,
        Report = function(s, e)
            success = false
            print(`{ e.Position.Line }:{ e.Position.Column }: { s }`)
        end,
    }

    -- TODO luau extraneous annotation
    local exprs: { Expression } = {}
    local tk = peekNextToken(state)

    while tk.Type ~= "EndOfFile" do
        local expr = parseExpression(state)
        assert(expr)

        table.insert(exprs, expr)
        tk = peekNextToken(state)
    end

    return { Success = success, Expressions = exprs }
end

local function makeLuauFuncValue(fn: ({ Value }) -> Value?): Value
    return {
        Type = "function",
        Value = {
            IsLuau = true,
            Function = fn,
        },
    }
end

function caw.valueToString(v: Value)
    if v.Type == "function" then
        return "function"
    elseif v.Type == "list" then
        local items = table.create<<string>>(#v.Value)

        for i, v in v.Value do
            items[i] = caw.valueToString(v)
        end

        return `\{ { table.concat(items, ", ") } \}`
    elseif v.Type == "Tuple" then
        local items = table.create<<string>>(#v.Value)

        for i, v in v.Value do
            items[i] = caw.valueToString(v)
        end

        return `\[ { table.concat(items, ", ") } \]`
    else
        return tostring(if v.Type == "Function" then "function" else v.Value)
    end
end

local function nilValue(): Value
    return { Type = "nil" }
end

local function booleanValue(b): Value
    return { Type = "boolean", Value = b }
end

local function numberValue(n): Value
    return { Type = "number", Value = n }
end

local function stringValue(s): Value
    return { Type = "string", Value = s }
end

local env: { [string]: Value? } = {
    print = makeLuauFuncValue(function(args)
        local str = ""

        for _, a in args do
            str ..= caw.valueToString(a) .. " "
        end

        str = string.sub(str, 1, #str - 1)
        print(str)

        return nil
    end),

    typeof = makeLuauFuncValue(function(args)
        assert(#args == 1, `'typeof' requires 1 argument.`)

        return stringValue(args[1].Type)
    end),

    tostring = makeLuauFuncValue(function(args)
        assert(#args == 1, `'tostring' requires 1 argument.`)

        return stringValue(caw.valueToString(args[1]))
    end),

    tonumber = makeLuauFuncValue(function(args)
        assert(#args == 1, `'tonumber' requires 1 argument.`)

        local v = args[1]
        assert(v.Type == "number" or v.Type == "string", `'tonumber' requires a string or number argument, got { v.Type } instead.`)

        local n = tonumber(v.Value)

        if n then
            return numberValue(n)
        else
            return nilValue()
        end
    end),

    list_clear = makeLuauFuncValue(function(args)
        assert(#args == 3, `'list_clear' requires 3 arguments.`)

        local l = args[1]
        assert(l.Type == "list", `'list_clear' expects a list as the first argument.`)

        local n = args[2]
        assert(n.Type == "number", `'list_clear' expects a number as the second argument.`)

        local init = args[3]

        table.clear(l.Value)

        for i = 1, n.Value do
            l.Value[i] = init
        end

        return nil
    end),
}

type CallFrame = {
    read VariadicArguments: { read Value },
}

local callFrames: { CallFrame } = {}
local runUnprotected

local function evaluate(expr: Expression): Value?
    assert(expr.Type ~= "InvalidSyntax")

    local function fail(msg): never
        error(`{ expr.Position.Line }:{ expr.Position.Column }: { msg }`)
    end

    if expr.Type == "Declaration" then
        local name = expr.Declaration.Name

        if env[name] then
            fail(`A binding with the name '{ name }' already exists.`)
        end

        local v = if expr.Declaration.Value then evaluate(expr.Declaration.Value) else nilValue()
        env[name] = v or nilValue()

        return v
    elseif expr.Type == "Call" then
        local id = expr.Call.Identifier
        local fn = env[id]

        if fn then
            if fn.Type ~= "function" then
                fail(`Cannot call a { fn.Type }.`)
                error(`Unreachable.`)
            end

            if not fn.Value.IsLuau and #expr.Call.Arguments < #fn.Value.Parameters then
                fail(`Function expects at least { #fn.Value.Parameters } argument(s) but only got { #expr.Call.Arguments }.`)
                error(`Unreachable.`)
            end

            local arguments = table.create<<Value>>(#expr.Call.Arguments)

            for i, a in expr.Call.Arguments do
                if a.Type == "Tuple" then
                    local varargs = callFrames[#callFrames].VariadicArguments

                    for vi, va in varargs do
                        arguments[i + vi - 1] = va
                    end
                else
                    arguments[i] = evaluate(a)
                end
            end

            if fn.Value.IsLuau then
                table.insert(callFrames, { VariadicArguments = {} })

                local returned = fn.Value.Function(arguments)

                table.remove(callFrames)
                return returned
            else
                for i, p in fn.Value.Parameters do
                    env[p] = arguments[i]
                end

                local variadicArgs = {}

                if #fn.Value.Parameters < #expr.Call.Arguments and fn.Value.Variadic then
                    for i = #fn.Value.Parameters + 1, #expr.Call.Arguments do
                        table.insert(variadicArgs, evaluate(expr.Call.Arguments[i]))
                    end
                end

                table.insert(callFrames, { VariadicArguments = variadicArgs })

                local success, data = pcall(runUnprotected, fn.Value.Body)

                table.remove(callFrames)

                local returned: Value?

                if success then
                    returned = data
                elseif typeof(data) == "table" and (data :: any).NormalReturn == true then
                    returned = (data :: any).NormalReturnValue
                else
                    error(data)
                end

                return returned
            end
        else
            fail(`Unknown function '{ expr.Call.Identifier }'.`)
            error(`Unreachable.`)
        end
    elseif expr.Type == "Constant" then
        return expr.Constant
    elseif expr.Type == "Reference" then
        local v = env[expr.Reference]

        if v then
            return v
        else
            fail(`Unknown reference '{ expr.Reference }'.`)
            error(`Unreachable.`)
        end

    elseif expr.Type == "BinaryOperation" then
        local leftEval = evaluate(expr.Left) or nilValue()
        local rightEval = evaluate(expr.Right) or nilValue()

        if expr.Operator == "==" or expr.Operator == "~=" or expr.Operator == ">" or expr.Operator == ">="
            or expr.Operator == "<" or expr.Operator == "<="
        then
            if expr.Operator ~= "==" and expr.Operator ~= "~=" then
                if leftEval.Type ~= "number" then
                    fail(`Expected LHS of '{ expr.Operator }' expression to be a number, got a { leftEval.Type } instead.`)
                    error(`Unreachable.`)
                end

                if rightEval.Type ~= "number" then
                    fail(`Expected RHS of '{ expr.Operator }' expression to be a number, got a { rightEval.Type } instead.`)
                    error(`Unreachable.`)
                end
            end

            local left = leftEval.Value
            local right = rightEval.Value

            if expr.Operator == "==" then
                return booleanValue(left == right)
            elseif expr.Operator == "~=" then
                return booleanValue(left ~= right)
            elseif expr.Operator == ">" then
                assert(typeof(left) == "number" and typeof(right) == "number")
                return booleanValue(left > right)
            elseif expr.Operator == ">=" then
                assert(typeof(left) == "number" and typeof(right) == "number")
                return booleanValue(left >= right)
            elseif expr.Operator == "<" then
                assert(typeof(left) == "number" and typeof(right) == "number")
                return booleanValue(left < right)
            elseif expr.Operator == "<=" then
                assert(typeof(left) == "number" and typeof(right) == "number")
                return booleanValue(left <= right)
            else
                unreachable(expr.Operator)
                error(`Unreachable.`)
            end
        elseif expr.Operator == ".." then
            if leftEval.Type ~= "string" then
                fail(`Expected LHS of '{ expr.Operator }' operation to be a string, got a { leftEval.Type } instead.`)
                error(`Unreachable.`)
            end

            if rightEval.Type ~= "string" then
                fail(`Expected RHS of '{ expr.Operator }' operation to be a string, got a { rightEval.Type } instead.`)
                error(`Unreachable.`)
            end

            return stringValue(leftEval.Value .. rightEval.Value)
        elseif expr.Operator == "=" then
            assert(expr.Left.Type == "Reference", "This should've been caught by the parser.")

            env[expr.Left.Reference] = rightEval
            return rightEval
        else
            if leftEval.Type ~= "number" then
                fail(`Expected LHS of '{ expr.Operator }' operation to be a number, got a { leftEval.Type } instead.`)
                error(`Unreachable.`)
            end

            if rightEval.Type ~= "number" then
                fail(`Expected RHS of '{ expr.Operator }' operation to be a number, got a { rightEval.Type } instead.`)
                error(`Unreachable.`)
            end

            local left = leftEval.Value
            local right = rightEval.Value

            if expr.Operator == "+" then
                return numberValue(left + right)
            elseif expr.Operator == "-" then
                return numberValue(left - right)
            elseif expr.Operator == "*" then
                return numberValue(left * right)
            elseif expr.Operator == "/" then
                return numberValue(left / right)
            elseif expr.Operator == "//" then
                return numberValue(left // right)
            else
                unreachable(expr.Operator)
                error(`Unreachable.`)
            end
        end
    elseif expr.Type == "UnaryOperation" then
        local operandEval = evaluate(expr.Operand) or nilValue()

        if expr.Operator == "-" then
            if operandEval.Type ~= "number" then
                fail(`Cannot negate a { operandEval.Type }.`)
                error(`Unreachable.`)
            end

            return numberValue(-operandEval.Value)
        elseif expr.Operator == "#" then
            if operandEval.Type == "string" or operandEval.Type == "list" then
                return numberValue(#operandEval.Value)
            else
                fail(`Cannot get the length of a { operandEval.Type }.`)
                error(`Unreachable.`)
            end
        else
            unreachable(expr.Operator)
            error(`Unreachable.`)
        end
    elseif expr.Type == "Function" then
        local params = table.create<<string>>(#expr.Function.Parameters)

        for i, p in expr.Function.Parameters do
            params[i] = p.Name
        end

        -- TODO luau extraneous annotation
        local f: Value = {
            Type = "function",
            Value = {
                IsLuau = false,
                Parameters = params,
                Variadic = expr.Function.Variadic.Present,
                Body = expr.Function.Body,
            },
        }

        if expr.Function.Name then
            env[expr.Function.Name] = f
        end

        return f
    elseif expr.Type == "Return" then
        assert(#callFrames > 1, "'return' expression appeared outside of a function call frame, this should've failed to parse.")

        error({
            NormalReturn = true,
            NormalReturnValue = if expr.Return then evaluate(expr.Return) else nil,
        })
    elseif expr.Type == "List" then
        local values = table.create<<Value>>(#expr.List)

        for i, v in expr.List do
            values[i] = evaluate(v)
        end

        return {
            Type = "list",
            Value = values,
        }
    elseif expr.Type == "VariadicArguments" then
        return callFrames[#callFrames].VariadicArguments[1] or nilValue()

    elseif expr.Type == "VariadicSelection" then
        local varargs = callFrames[#callFrames].VariadicArguments
        local index = evaluate(expr.Selection) or nilValue()
        assert(index.Type == "number", `Variadic selection was expected to be a number, got { index.Type }.`)

        return varargs[index.Value] or nilValue()

    elseif expr.Type == "VariadicLength" then
        local varargs = callFrames[#callFrames].VariadicArguments
        return numberValue(#varargs)

    elseif expr.Type == "IfCondition" then
        local conditionResult = evaluate(expr.Condition) or nilValue()

        if conditionResult.Type ~= "boolean" then
            fail(`Expected boolean for condition, got { conditionResult.Type }.`)
            error(`Unreachable.`)
        end

        if conditionResult.Value == true then
            conditionResult = runUnprotected(expr.IfBody)
        elseif expr.ElseBody then
            conditionResult = runUnprotected(expr.ElseBody)
        end

        return conditionResult
    elseif expr.Type == "ReadIndex" then
        local list = evaluate(expr.List) or nilValue()
        assert(list.Type == "list", `Expected a list as the indexed value, got { list.Type }.`)

        local index = evaluate(expr.Index) or nilValue()
        assert(index.Type == "number", `Expected a number as the index value, got { index.Type }.`)

        return list.Value[index.Value]
    elseif expr.Type == "WriteIndex" then
        local list = evaluate(expr.List) or nilValue()
        assert(list.Type == "list", `Expected a list as the indexed value, got { list.Type }.`)

        local index = evaluate(expr.Index) or nilValue()
        assert(index.Type == "number", `Expected a number as the index value, got { index.Type }.`)

        local value = evaluate(expr.Value) or nilValue()
        list.Value[index.Value] = value

        return value
    elseif expr.Type == "TypeAliasDeclaration" then
        return nilValue()
    else
        unreachable(expr.Type)
        error(`Unreachable.`)
    end
end

function runUnprotected(exprs: { read Expression }): Value?
    local last = nil

    for _, expr in exprs do
        local result = evaluate(expr)

        if expr.Type == "Return" then
            return result
        end

        last = result
    end

    return last
end

function caw.run(exprs: { read Expression }): Value?
    callFrames = { { VariadicArguments = {} } }

    local success, data = pcall(runUnprotected, exprs)

    table.remove(callFrames)

    if success then
        return data
    else
        local msg = tostring(data)
        local _, p = string.find(msg, ".luau:%d+:")

        while p do
            msg = string.sub(msg, p + 2, #msg)
            _, p = string.find(msg, ".luau:%d+:")
        end

        print(`Protected error: { msg }`)
        return nil
    end
end

return table.freeze(caw)
