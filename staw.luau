-- staw.luau, 22/11/2026
local caw = require("./caw")
local awn = require("./awn")

local tests: { { read name: string, read run: () -> () } } = {}

local function test(name: string, fn: () -> ())
    table.insert(tests, { name = name, run = fn })
end

local function expect<T>(value: T)
    local t = {}

    function t.toBe(other: T)
        if value ~= other then
            error(`FAILTEST: "{ value }" ({ typeof(value) }) was not "{ other }" ({ typeof(other) }).`)
        end
    end

    return t
end

type CheckResult = {
    read errors: { read string },
    read localTypeEnv: { read [string]: awn.Type? },
    read localTypeAssociations: { read [string]: { read Expression: caw.Expression, read Type: awn.Type }? },
}

local function check(source): CheckResult
    local errors: { string } = {}

    local parse = caw.parse(source)
    -- TODO luau cast.
    table.move(parse.errors :: any, 1, #parse.errors, 1, errors)

    local solverResult = awn.run(parse.expressions, { LogInference = false })
    table.move(solverResult.typeErrors :: any, 1, #solverResult.typeErrors, #errors + 1, errors)

    return {
        errors = errors,
        localTypeEnv = solverResult.localTypeEnv,
        localTypeAssociations = solverResult.localTypeAssociations,
    }
end

local function requireNoErrors(result: CheckResult)
    if #result.errors > 0 then
        -- TODO luau cast.
        error(`FAILTEST: Got { #result.errors } error(s):\n* { table.concat(result.errors :: any, "\n* ") }`)
    end

    return result
end

local function requireError(result: CheckResult, error: string?)
    expect(#result.errors).toBe(1)

    if error then
        expect(result.errors[1]).toBe(error)
    end

    return result
end

local function expectType(result: CheckResult, name: string)
    local var = result.localTypeAssociations[name]

    if not var then
        error(`FAILTEST: '{ name }' was not defined.`)
    end

    return expect(awn.typeToString(var.Type))
end

test("infer() Declaration Constant", function()
    requireNoErrors(check("let x = 5"))
end)

test("infer() Declaration Singleton", function()
    requireNoErrors(check("let x = \"hello\""))
end)

test("error infer() Declaration void", function()
    requireError(check("let x = print(1)"), "1:3: Trying to assign 'x' to an expression returning no values.")
end)

test("infer() Declaration annotated", function()
    requireNoErrors(check("let x: number = 1"))
end)

test("infer() Reference", function()
    requireNoErrors(check("print"))
end)

test("error infer() Reference", function()
    requireError(check("nonexistent"), "1:3: Invalid reference 'nonexistent'.")
end)

test("infer() List empty", function()
    requireNoErrors(check("let x = {}"))
end)

test("infer() List with items", function()
    -- TODO PROVISIONAL
    expectType(requireNoErrors(check("let x = { 1, true }")), "x")
        .toBe("{ (number | true <: 'a) }")
end)

test("infer() ReadIndex", function()
    requireNoErrors(check("let x = {} let y = x[1]"))
end)

test("infer() WriteIndex", function()
    requireNoErrors(check("let x = {} x[1] = true"))
end)

test("error infer() WriteIndex void", function()
    requireError(check("let x = {} x[1] = print(1)"), "1:29: Tried to assign list index to an expression that returns no value.")
end)

test("infer() UnaryOperation '-'", function()
    requireNoErrors(check("-1"))
end)

test("error infer() UnaryOperation '-' void", function()
    requireError(check("-print(1)"), "1:5: Attempted to use '-' on expression that returns no value.")
end)

test("infer() UnaryOperation '#'", function()
    requireNoErrors(check("#{}"))
end)

test("infer() UnaryOperation '#'", function()
    requireError(check("#print(1)"), "1:5: Attempted to use '#' on expression that returns no value.")
end)

test("infer() BinaryOperation '='", function()
    requireNoErrors(check("let x = 1 x = 2"))
end)

test("error infer() BinaryOperation '=' undefined", function()
    requireError(check("x = 2"), "1:3: Undefined variable 'x'.")
end)

test("error infer() BinaryOperation '=' builtins", function()
    requireError(check("print = 2"), "1:3: Cannot assign to builtins.")
end)

test("error infer() BinaryOperation '=' void", function()
    requireError(check("let x = 1 x = print(1)"), "1:15: Tried to assign 'x' to an expression that returns no value.")
end)

test("infer() BinaryOperation '=' function parameter", function()
    expectType(requireNoErrors(check("function f(x) x = 1 end")), "f").toBe("(number) -> ()")
end)

test("infer() BinaryOperation '=' function parameter non-free", function()
    expectType(requireNoErrors(check("function f(x: number) x = 1 end")), "f").toBe("(number) -> ()")
end)

test("infer() BinaryOperation '=' annotated", function()
    requireNoErrors(check("let x: number = 1 x = 2"))
end)

test("infer() BinaryOperation arithmetic", function()
    requireNoErrors(check([[
        let x = 1
        x + 1
        x - 1
        x * 1
        x / 1
        x // 1
    ]]))
end)

test("error infer() BinaryOperation arithmetic void LHS", function()
    expect(#check([[
        print(1) + 1
        print(1) - 1
        print(1) * 1
        print(1) / 1
        print(1) // 1
    ]]).errors).toBe(5)
end)

test("error infer() BinaryOperation arithmetic void RHS", function()
    expect(#check([[
        1 + print(1)
        1 - print(1)
        1 * print(1)
        1 / print(1)
        1 // print(1)
    ]]).errors).toBe(5)
end)

test("infer() BinaryOperation ..", function()
    expectType(requireNoErrors(check("let x = \"a\" .. \"b\"")), "x").toBe("string")
end)

test("error infer() BinaryOperation .. void LHS", function()
    requireError(check("print(1) .. \"b\""), "1:3: LHS is expression returning no value.")
end)

test("error infer() BinaryOperation .. void RHS", function()
    requireError(check("\"a\" .. print(1)"), "1:9: RHS is expression returning no value.")
end)

test("infer() BinaryOperation numeric logical", function()
    requireNoErrors(check([[
        let x = 1
        x < 1
        x <= 1
        x > 1
        x >= 1
    ]]))
end)

test("error infer() BinaryOperation numeric logical void LHS", function()
    expect(#check([[
        print(1) < 1
        print(1) <= 1
        print(1) > 1
        print(1) >= 1
    ]]).errors).toBe(4)
end)

test("error infer() BinaryOperation numeric logical void RHS", function()
    expect(#check([[
        1 < print(1)
        1 <= print(1)
        1 > print(1)
        1 >= print(1)
    ]]).errors).toBe(4)
end)

test("infer() BinaryOperation logical equality", function()
    requireNoErrors(check("1 == 2 ~= 3"))
end)

test("error infer() BinaryOperation logical equality void LHS", function()
    requireError(check("print(1) == 1"))
end)

test("error infer() BinaryOperation logical equality void RHS", function()
    requireError(check("1 == print(1)"))
end)

test("error infer() BinaryOperation '#'", function()
    requireError(check("1 # 2"))
end)

test("infer() Function explicit generics", function()
    requireNoErrors(check("function f<T>(x: T): T return x end"))
end)

test("infer() Function unit return type", function()
    expectType(requireNoErrors(check("function f(): () end")), "f").toBe("() -> ()")
end)

test("infer() Function expected return", function()
    requireNoErrors(check("let f: () -> number = function() return 5 end"))
end)

test("infer() Function expected return void", function()
    requireNoErrors(check("let f: () -> () = function() end"))
end)

test("infer() Function variadic", function()
    expectType(requireNoErrors(check("function f(...) end")), "f").toBe("(...unknown) -> ()")
end)

test("infer() Return inferred first", function()
    expectType(requireNoErrors(check("function f() return 5 end")), "f").toBe("() -> number")
end)

test("infer() Return inferred first void", function()
    expectType(requireNoErrors(check("function f() return end")), "f").toBe("() -> ()")
end)

test("error infer() Return no value got return", function()
    requireError(check("function f(): () return 1 end"))
end)

test("error infer() Return annotation returning void", function()
    requireError(check("function f(): number return end"))
end)

test("error infer() Return outside function", function()
    requireError(check("return"))
end)

test("error infer() Call unknown", function()
    requireError(check("foo()"))
end)

test("error infer() Call erroenous implicit generic instantiation", function()
    requireError(check("function id(x) return x end let y: string = id(1)"))
end)

test("error infer() Call not callable", function()
    requireError(check("let x = 1 x()"))
end)

test("infer() Call simple overload resolution", function()
    expectType(requireNoErrors(check([[
        let f: ((number) -> boolean) & ((string) -> number) = valuenever
        let x = f(1)
    ]])), "x").toBe("boolean")
end)

test("error infer() Call simple overload resolution arity mismatch", function()
    expectType(requireError(check([[
        let f: ((number) -> boolean) & ((string) -> number) = valuenever
        let x = f(1, 2)
    ]])), "x").toBe("*error*")
end)

test("error infer() Call simple overload resolution type mismatch", function()
    expectType(requireError(check([[
        let f: ((number) -> boolean) & ((string) -> number) = valuenever
        let x = f(nil)
    ]])), "x").toBe("*error*")
end)

test("infer() Call normalized overload resolution", function()
    expectType(requireNoErrors(check([[
        let f: ((true) -> number) & ((false) -> nil) = valuenever
        let x: boolean = true
        let y = f(x)
    ]])), "y").toBe("nil | number")
end)

test("infer() IfCondition", function()
    expectType(requireNoErrors(check([[
        let x = if 1 then
            true
        else
            nil
        end
    ]])), "x").toBe("true | nil")
end)

test("infer() VariadicArguments", function()
    expectType(requireNoErrors(check([[
        function f(...)
            let x = ...
            return x
        end
    ]])), "f").toBe("<U>(...U) -> U")
end)

test("error infer() VariadicArguments", function()
    expectType(requireError(check([[
        function f()
            let x = ...
            return x
        end
    ]])), "f").toBe("() -> *error*")
end)

test("infer() VariadicSelection", function()
    expectType(requireNoErrors(check([[
        function f(x, ...)
            return ...[x]
        end
    ]])), "f").toBe("<U>(number, ...U) -> U")
end)

test("error infer() VariadicSelection void", function()
    expectType(requireError(check([[
        function f(...)
            return ...[print(1)]
        end
    ]])), "f").toBe("<U>(...U) -> U")
end)

test("error infer() VariadicSelection not variadic", function()
    expectType(requireError(check([[
        function f()
            return ...[print(1)]
        end
    ]])), "f").toBe("() -> *error*")
end)

test("infer() VariadicLength", function()
    expectType(requireNoErrors(check([[
        function f(...)
            return #...
        end
    ]])), "f").toBe("(...unknown) -> number")
end)

test("error infer() VariadicLength", function()
    expectType(requireError(check([[
        function f()
            return #...
        end
    ]])), "f").toBe("() -> number")
end)

test("infer() TypeAliasDeclaration", function()
    requireNoErrors(check([[
        type x = number
    ]]))
end)

test("error infer() TypeAliasDeclaration redefinition", function()
    requireError(check([[
        type string = number
    ]]))
end)

test("infer() TypeAliasDeclaration generic", function()
    requireNoErrors(check([[
        type test<T> = { T }
    ]]))
end)

test("error check()", function()
    requireError(check([[
        let x: number = true
    ]]))
end)

test("reduceTypeFunctions()", function()
    expectType(requireNoErrors(check([[
        let x: items<{ number }> = 5
    ]])), "x").toBe("number")
end)

test("reduceTypeFunctions() stuck", function()
    expectType(requireNoErrors(check([[
        type test<T> = items<T> | nil
        let x: test<{ number }> = 1
    ]])), "x").toBe("number | nil")
end)

test("error reduceTypeFunctions() failed", function()
    expectType(requireError(check([[
        let x: items<nil> = valuenever
    ]])), "x").toBe("*error*")
end)

test("error reduceTypeFunctions() type alias wrong number of generic arguments", function()
    requireError(check([[
        type test<T> = { T }
        let x: test<true, false> = 1
    ]]))
end)

test("error reduceTypeFunctions() does not accept type arguments", function()
    requireError(check([[
        let x: number<true> = 1
    ]]))
end)

test("error reduceTypeFunctions() invalid type function", function()
    requireError(check([[
        let x: foo<true> = 1
    ]]))
end)

--[[
test("incomplete type alias instantiation", function()
    local result = check("type T = U<a")
    expect(#result.errors).toBe(2)
    expect(result.errors[1]).toBe("1:18: Expected '>', but reached end-of-file.")
    expect(result.errors[2]).toBe("1:3: Unknown type 'a'.")
end)

test("recursive parameter bounds", function()
    requireNoErrors(check("function f(x, y) x = y y = x end"))
end)]]

local function runTests()
    local succeeded = 0
    local failed = 0

    for _, t in tests do
        local s, e = pcall(t.run)

        if s then
            succeeded += 1
        else
            print(`"{ t.name }" failed: { e }`)
            failed += 1
        end
    end

    print(`{ succeeded } succeeded, { failed } failed.`)
end

return runTests
