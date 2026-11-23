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
    expectErrorCount(result).toBe(0)
end

test("infer constant", function()
    requireNoErrors(check("let x = 5"))
end)

test("infer singleton", function()
    requireNoErrors(check("let y = \"hello\""))
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
