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

local function expectErrorCount(result: CheckResult)
    return expect(#result.errors)
end

local function requireNoErrors(result: CheckResult)
    if #result.errors > 0 then
        -- TODO luau cast.
        error(`FAILTEST: Got { #result.errors } error(s):\n* { table.concat(result.errors :: any, "\n* ") }`)
    end

    return result
end

local function requireError(result: CheckResult, error: string)
    expectErrorCount(result).toBe(1)
    expect(result.errors[1]).toBe(error)

    return result
end

local function expectType(result: CheckResult, name: string)
    local var = result.localTypeAssociations[name]

    if not var then
        error(`FAILTEST: '{ name }' was not defined.`)
    end

    return expect(awn.typeToString(var.Type))
end

test("infer declaration constant", function()
    requireNoErrors(check("let x = 5"))
end)

test("infer declaration singleton", function()
    requireNoErrors(check("let x = \"hello\""))
end)

test("error infer declaration void", function()
    requireError(check("let x = print(1)"), "1:3: Trying to assign 'x' to an expression returning no values.")
end)

test("infer declaration annotated", function()
    requireNoErrors(check("let x: number = 1"))
end)

test("infer reference", function()
    requireNoErrors(check("print"))
end)

test("error infer reference", function()
    requireError(check("nonexistent"), "1:3: Invalid reference 'nonexistent'.")
end)

test("infer list empty", function()
    requireNoErrors(check("let x = {}"))
end)

test("infer list with items", function()
    -- TODO PROVISIONAL
    expectType(requireNoErrors(check("let x = { 1, true }")), "x")
        .toBe("{ (number | true <: 'b) }")
end)

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
