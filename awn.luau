-- awn.luau, 09/09/2026
-- Bidirectional inference with semantic subtyping and normalization.

-- https://pnwamk.github.io/sst-tutorial/
-- https://rfcs.luau.org/local-type-inference.html
-- https://rfcs.luau.org/lower-bounds-calculation.html
-- https://luau.org/news/2022-10-31-luau-semantic-subtyping/
-- https://www.cduce.org/papers/gentle.pdf

local awn = {}

local caw = require("./caw")
local logInference = false
local typeErrors = {}

type ErrorType = {
    read Kind: "error",
}

type UnknownType = {
    read Kind: "unknown",
}

type NeverType = {
    read Kind: "never",
}

-- "Unknown"  = Not yet determined.
-- "Negative" = Appears in contravariant positions only, take upper bound when eliminating.
-- "Positive" = Appears in covariant positions only, take lower bound when eliminating.
-- "Mixed"    = Appears in both kinds of positions, generalize.
type Polarity = "Unknown" | "Negative" | "Positive" | "Mixed"

type FreeType = {
    read Kind: "Free",
    UpperBound: Type,
    LowerBound: Type,
}

type GenericType = {
    read Kind: "Generic",
    read Name: string?,
}

-- Types of the form `T<U>`, where they may have generics that need to be substituted,
-- or are type functions.
type PendingExpansionType = {
    read Kind: "PendingExpansion",
    read Name: string,
    read Arguments: { read Type },
}

type PrimitiveType = {
    read Kind: "Primitive",
    read Primitive: "nil" | "boolean" | "number" | "string" | "list" | "function"
}

type SingletonType = {
    read Kind: "Singleton",
    read Value: string | boolean,
}

type ListType = {
    read Kind: "List",
    read Items: Type,
}

type FunctionType = {
    read Kind: "Function",
    read Generics: { read Type },
    read Parameters: { read Type },
    read Variadic: Type,
    read Returns: Type?,
}

type NegationType = {
    read Kind: "Negation",
    read Negated: Type,
}

type UnionType = {
    read Kind: "Union",
    read Components: { read Type },
}

type IntersectionType = {
    read Kind: "Intersection",
    read Components: { read Type },
}

type TypeData =
    | ErrorType
    | NeverType
    | UnknownType
    | PrimitiveType
    | ListType
    | SingletonType
    | GenericType
    | FunctionType
    | PendingExpansionType
    | NegationType
    | UnionType
    | IntersectionType
    | FreeType

export type Type = { AliasName: string? } & TypeData

type NormalizedBooleanType = {
    read hasTrue: boolean,
    read hasFalse: boolean
}

type NormalizedStringType = {
    -- If `true`, we start from `string` and `singletons` are an intersection of negations with us.
    -- If `false`, we start from `never` and `singletons` are a union.
    read cofinite: boolean,
    read singletons: { read [string]: nil | true },
}

type NormalizedFunctionComponentType = {
    read generics: { read Type },
    read parameters: { read NormalizedType },
    read variadic: NormalizedType,
    read returns: NormalizedType?,
}

type NormalizedFunctionType = {
    -- `nil` = top 'function' type.
    read components: { read NormalizedFunctionComponentType }?
}

export type NormalizedType = {
    aliasName: string?,
    read errors:   boolean,
    read nils:     boolean,
    read booleans: NormalizedBooleanType,
    read numbers:  boolean,
    read strings:  NormalizedStringType,
    -- If `items` is not present, we're the top.
    read lists: { read items: NormalizedType? }?,
    -- `nil` = not present.
    read functions: NormalizedFunctionType?,
    -- Union of generic/free/pending expansion types. Key is the type, value is what it is being intersected with
    -- (by default, `unknown`.)
    read pending: { read [Type]: NormalizedType? }?,
}

local function unreachable(x: never): never
    error(`Unexpected branch with value '{ x }' ({ typeof(x) }), this is an internal error.`, 2)
end

local function log(message: string)
    if logInference then
        print(message)
    end
end

local function makeType(ty: TypeData): Type
    local t = ty :: Type
    -- `AliasName`.
    return t
end

local errorType = makeType{ Kind = "error" }
local neverType = makeType{ Kind = "never" }
local unknownType = makeType{ Kind = "unknown" }
local nilType = makeType{ Kind = "Primitive", Primitive = "nil" }
local booleanType = makeType{ Kind = "Primitive", Primitive = "boolean" }
local numberType = makeType{ Kind = "Primitive", Primitive = "number" }
local stringType = makeType{ Kind = "Primitive", Primitive = "string" }
local topListType = makeType{ Kind = "Primitive", Primitive = "list" }
local topFunctionType = makeType{ Kind = "Primitive", Primitive = "function" }

local function freeType(upper: Type?, lower: Type?)
    return makeType{
        Kind = "Free",
        UpperBound = upper or unknownType,
        LowerBound = lower or neverType,
    }
end

local function genericType(name: string?)
    return makeType{
        Kind = "Generic",
        Name = name,
    }
end

local function pendingExpansionType(name: string, arguments: { read Type })
    return makeType{
        Kind = "PendingExpansion",
        Name = name,
        Arguments = arguments,
    }
end

local function singletonType(value)
    return makeType{
        Kind = "Singleton",
        Value = value,
    }
end

local function listType(items: Type)
    return makeType{
        Kind = "List",
        Items = items,
    }
end

local function functionType(generics: { read Type }, parameters: { read Type }, variadic: Type, returns: Type?)
    return makeType{
        Kind = "Function",
        Generics = generics,
        Parameters = parameters,
        Variadic = variadic,
        Returns = returns,
    }
end

local function negationType(negated: Type)
    return makeType{
        Kind = "Negation",
        Negated = negated,
    }
end

local function unionType(components: { read Type })
    return makeType{
        Kind = "Union",
        Components = components,
    }
end

local function intersectionType(components: { read Type })
    return makeType{
        Kind = "Intersection",
        Components = components,
    }
end

local function errorReport(message, position: caw.Position): Type
    table.insert(typeErrors, `{ position.Line }:{ position.Column }: { message }`)
    return errorType
end

local function makeUnion(a: Type, b: Type)
    -- TODO luau cast.
    a = a :: any
    b = b :: any

    if a.Kind == "never" then
        return b
    elseif b.Kind == "never" then
        return a
    end

    local components: { Type } = {}

    if a.Kind == "Union" then
        table.move(a.Components, 1, #a.Components, 1, components)
    else
        components[1] = a
    end

    if b.Kind == "Union" then
        table.move(b.Components, 1, #b.Components, 1, components)
    else
        table.insert(components, b)
    end

    return makeType{
        Kind = "Union",
        Components = components,
    }
end

local function makeIntersection(a: Type, b: Type)
    -- TODO luau cast.
    a = a :: any
    b = b :: any

    if a.Kind == "unknown" then
        return b
    elseif b.Kind == "unknown" then
        return a
    end

    local components: { Type } = {}

    if a.Kind == "Intersection" then
        table.move(a.Components, 1, #a.Components, 1, components)
    else
        components[1] = a
    end

    if b.Kind == "Intersection" then
        table.move(b.Components, 1, #b.Components, 1, components)
    else
        table.insert(components, b)
    end

    return makeType{
        Kind = "Intersection",
        Components = components,
    }
end

local function normalizedNever(): NormalizedType
    return {
        errors = false,
        nils = false,
        booleans = { hasTrue = false, hasFalse = false },
        numbers = false,
        strings = { cofinite = false, singletons = {} },
        functions = nil,
    }
end

local function normalizedUnknown(): NormalizedType
    return {
        errors = false,
        nils = true,
        booleans = { hasTrue = true, hasFalse = true },
        numbers = true,
        strings = { cofinite = true, singletons = {} },
        lists = {},
        functions = {},
    }
end

local function isBooleanNever(b: NormalizedBooleanType)
    return b.hasTrue == false and b.hasFalse == false
end

local function isBooleanTop(b: NormalizedBooleanType)
    return b.hasTrue == true and b.hasFalse == true
end

local function isStringNever(s: NormalizedStringType)
    -- TODO luau cast.
    return not s.cofinite and next(s.singletons :: any) == nil
end

local function isStringTop(s: NormalizedStringType)
    -- TODO luau cast.
    return s.cofinite and next(s.singletons :: any) == nil
end

local function isNever(n: NormalizedType)
    return not n.nils
        and isBooleanNever(n.booleans)
        and not n.numbers
        and isStringNever(n.strings)
        and not n.lists
        and not n.functions
        and not n.pending
end

local function isUnknown(n: NormalizedType)
    -- Check for all tops.
    return not not (
        n.nils
        and isBooleanTop(n.booleans)
        and n.numbers
        and isStringTop(n.strings)
        and (n.lists and not n.lists.items)
        and (n.functions and not n.functions.components)
    )
end

-- Some types do not support negation with the current normalization implementation (discrete a.k.a. non-top lists and functions).
-- The "pending" types (generics, type function instances, and free types), however, have no theoretical negation.
local function hasNonNegatables(n: NormalizedType): boolean
    return not not (
        (n.lists and n.lists.items)
        or (n.functions and n.functions.components)
        -- TODO luau cast.
        or (n.pending and next(n.pending :: any) ~= nil)
    )
end

local function negate(n: NormalizedType): NormalizedType
    local errors = n.errors

    if hasNonNegatables(n) then
        table.insert(typeErrors, `Type has non-negatables, such as discrete (non-top) lists, functions, generics, type functions, or free types.`)
        errors = true
    end

    local strings = { cofinite = not n.strings.cofinite, singletons = n.strings.singletons }

    return {
        errors = errors,
        nils = not n.nils,
        booleans = { hasTrue = not n.booleans.hasTrue, hasFalse = not n.booleans.hasFalse },
        numbers = not n.numbers,
        strings = strings,
        lists = if n.lists then nil else {},
        functions = if n.functions then nil else {},
    }
end

local function union(a: NormalizedType, b: NormalizedType): NormalizedType
    local errors = a.errors or b.errors
    local nils = a.nils or b.nils
    local numbers = a.numbers or b.numbers

    local booleans = {
        hasTrue = a.booleans.hasTrue or b.booleans.hasTrue,
        hasFalse = a.booleans.hasFalse or b.booleans.hasFalse
    }

    local strings = { cofinite = false, singletons = {} }

    if not isStringNever(a.strings) and not isStringNever(b.strings) then
        local aStrings = a.strings
        local bStrings = b.strings
        local aSingles = aStrings.singletons
        local bSingles = bStrings.singletons

        -- TODO luau cast.
        if next(aSingles :: any) ~= nil and next(bSingles :: any) ~= nil then
            local singles: { [string]: true } = {}

            -- TODO check
            for s, _ in aSingles do
                if bSingles[s] then
                    if bStrings.cofinite == aStrings.cofinite then
                        if not aStrings.cofinite then
                            singles[s] = true
                        end
                    end
                else
                    singles[s] = true
                end
            end

            for s, _ in bSingles do
                if aSingles[s] then
                    if aStrings.cofinite == bStrings.cofinite then
                        if not bStrings.cofinite then
                            singles[s] = true
                        end
                    end
                else
                    singles[s] = true
                end
            end

            strings = { cofinite = false, singletons = singles }
        elseif not aStrings.cofinite and not bStrings.cofinite then
            local singles: { [string]: true } = {}

            for s, _ in aSingles do
                singles[s] = true
            end

            for s, _ in bSingles do
                singles[s] = true
            end

            strings = { cofinite = false, singletons = singles }
        else
            -- `"a" | string` and `string | "a"` => `string`
            -- `(string & ~"a") | string` and `string | (string & | "a")` => `string`
            strings = { cofinite = true, singletons = {} }
        end
    else
        -- One is `never`.
        strings = if isStringNever(a.strings) then b.strings
                    else a.strings
    end

    local lists = nil

    if a.lists and b.lists then
        local aItems = a.lists.items
        local bItems = b.lists.items

        if aItems and bItems then
            local result = awn.isExactly(aItems, bItems)

            if result.holds then
                lists = { items = aItems }
            else
                -- Reading from it would be a union, writing to it would be an intersection.
                -- This is not representible currently.
                lists = { items = normalizedNever() }
            end
        else
            -- Top.
            lists = {}
        end
    else
        -- One is `never`.
        lists = a.lists or b.lists
    end

    local functions = nil

    if a.functions and b.functions then
        local aComponents = a.functions.components
        local bComponents = b.functions.components

        if aComponents and bComponents then
            local components = table.create<<NormalizedFunctionComponentType>>(#aComponents + #bComponents)
            -- TODO luau cast.
            table.move(aComponents :: any, 1, #aComponents, 1, components)

            for _, bComponent in bComponents do
                local bf = { components = { bComponent } }
                local redundant = false
                local failed = false

                for i, component in components do
                    local af = { components = { component } }

                    -- If `A <: B`, then `A | B = B`.
                    if awn.isFunctionSubtypeOf(bf, af).holds then
                        redundant = true
                        break
                    elseif awn.isFunctionSubtypeOf(af, bf).holds then
                        components[i] = bComponent
                        redundant = true
                        break
                    else
                        table.insert(typeErrors, `Cannot union unrelated discrete function types.`)
                        failed = true
                        errors = true
                    end
                end

                if failed then
                    break
                end

                if not redundant then
                    table.insert(components, bComponent)
                end
            end

            functions = { components = components }
        else
            -- Top.
            functions = {}
        end
    else
        -- One is `never`.
        functions = a.functions or b.functions
    end

    local pending = nil

    if a.pending and b.pending then
        local nowPending: { [Type]: NormalizedType } = {}

        for ty, intersect in a.pending do
            local otherIntersect = b.pending[ty]

            if otherIntersect then
                -- `(T & string) | (T & nil)`
                -- ... sub `T = string?` ...
                -- `(string? & string) | (string? & nil)`
                -- a.k.a. `(string) | (nil)` a.k.a. `string?`
                -- a.k.a. `string? & string?`

                -- Union the intersectors.
                nowPending[ty] = union(intersect, otherIntersect)
            else
                nowPending[ty] = intersect
            end
        end

        pending = nowPending
    else
        pending = a.pending or b.pending
    end

    return {
        errors = errors,
        nils = nils,
        booleans = booleans,
        numbers = numbers,
        strings = strings,
        lists = lists,
        functions = functions,
        pending = pending,
    }
end

local function intersect(a: NormalizedType, b: NormalizedType, inside: { [Type]: true? }?): NormalizedType
    local errors = a.errors or b.errors
    local nils = a.nils and b.nils
    local numbers = a.numbers and b.numbers

    local booleans = {
        hasTrue = a.booleans.hasTrue and b.booleans.hasTrue,
        hasFalse = a.booleans.hasFalse and b.booleans.hasFalse
    }

    local strings = { cofinite = false, singletons = {} }

    if not isStringNever(a.strings) and not isStringNever(b.strings) then
        local aStrings = a.strings
        local bStrings = b.strings
        local aSingles = aStrings.singletons
        local bSingles = bStrings.singletons

        local aHasSingles = next(aSingles :: any) ~= nil
        local bHasSingles = next(bSingles :: any) ~= nil

        -- TODO luau cast.
        if aHasSingles and bHasSingles then
            local singles: { [string]: true } = {}

            if aStrings.cofinite == bStrings.cofinite then
                for s, _ in aSingles do
                    if bSingles[s] then
                        singles[s] = true
                    end
                end

                strings = { cofinite = aStrings.cofinite, singletons = singles }
            else
                for s, _ in aSingles do
                    if not bSingles[s] then
                        singles[s] = true
                    end
                end

                strings = { cofinite = aStrings.cofinite, singletons = singles }
            end
        else
            strings = if aHasSingles then aStrings
                        else if bHasSingles then bStrings
                        else { cofinite = true, singletons = {} }
        end
    end

    local lists = nil

    if a.lists and b.lists then
        local aItems = a.lists.items
        local bItems = b.lists.items

        if aItems and bItems then
            local result = awn.isExactly(aItems, bItems)

            if result.holds then
                lists = { items = aItems }
            else
                -- Reading from it would be an intersection, writing to it would be an union (I think).
                -- This is not representible currently.
                lists = { items = normalizedNever() }
            end
        else
            lists = { items = aItems or bItems }
        end
    end

    local functions = nil

    if a.functions and b.functions then
        local aComponents = a.functions.components
        local bComponents = b.functions.components

        if aComponents and bComponents then
            local components = table.create<<NormalizedFunctionComponentType>>(#aComponents + #bComponents)
            -- TODO luau cast.
            table.move(aComponents :: any, 1, #aComponents, 1, components)

            for _, bComponent in bComponents do
                local bf = { components = { bComponent } }
                local redundant = false

                for i, component in components do
                    local af = { components = { component } }

                    -- If `A <: B`, then `A & B = A`.
                    if awn.isFunctionSubtypeOf(bf, af).holds then
                        components[i] = bComponent
                        redundant = true
                        break
                    elseif awn.isFunctionSubtypeOf(af, bf).holds then
                        redundant = true
                        break
                    end
                end

                if not redundant then
                    table.insert(components, bComponent)
                end
            end

            functions = { components = components }
        else
            functions = { components = aComponents or bComponents }
        end
    end

    local pending: { [Type]: NormalizedType }? = nil

    if a.pending then
        pending = {}

        for ty, intersectsWith in a.pending do
            local nowInside = inside or {}

            if nowInside[ty] then
                continue
            end
            nowInside[ty] = true

            pending[ty] = intersect(intersectsWith, b)

            nowInside[ty] = nil
        end
    end

    if b.pending then
        pending = pending or {}
        assert(pending)

        for ty, intersectsWith in b.pending do
            local nowInside = inside or {}

            if nowInside[ty] then
                continue
            end
            nowInside[ty] = true

            if pending[ty] then
                pending[ty] = intersect(pending[ty], a, nowInside)
            else
                pending[ty] = intersect(intersectsWith, a, nowInside)
            end

            nowInside[ty] = nil
        end
    end

    return {
        errors = errors,
        nils = nils,
        booleans = booleans,
        numbers = numbers,
        strings = strings,
        lists = lists,
        functions = functions,
        pending = pending,
    }
end

local function normalize_(ty: Type, inside: { [Type]: true? }): NormalizedType
    if inside[ty] then
        return normalize_(errorType, {})
    end
    inside[ty] = true

    local errors = false
    local nils = false
    local booleans = { hasTrue = false, hasFalse = false }
    local numbers = false
    local strings = { cofinite = false, singletons = {} }
    local lists = nil
    local functions = nil
    local pending: { [Type]: NormalizedType }? = nil

    if ty.Kind == "error" then
        errors = true
    elseif ty.Kind == "unknown" then
        nils = true
        booleans.hasTrue = true
        booleans.hasFalse = true
        numbers = true
        strings.cofinite = true
        lists = {}
        functions = {}
    elseif ty.Kind == "never" then
        -- Default state.
    elseif ty.Kind == "Free" or ty.Kind == "Generic" or ty.Kind == "PendingExpansion" then
        local nowPending = pending or {}

        nowPending[ty] = normalizedUnknown()
        pending = nowPending
    elseif ty.Kind == "Primitive" then
        if ty.Primitive == "nil" then
            nils = true
        elseif ty.Primitive == "boolean" then
            booleans.hasTrue = true
            booleans.hasFalse = true
        elseif ty.Primitive  == "number" then
            numbers = true
        elseif ty.Primitive == "string" then
            strings.cofinite = true
        elseif ty.Primitive == "list" then
            lists = {}
        elseif ty.Primitive == "function" then
            functions = {}
        else
            unreachable(ty.Primitive)
        end
    elseif ty.Kind == "Singleton" then
        if typeof(ty.Value) == "boolean" then
            if ty.Value then
                booleans.hasTrue = true
            else
                booleans.hasFalse = true
            end
        elseif typeof(ty.Value) == "string" then
            strings.singletons[ty.Value] = true :: true -- TODO luau cast.
        else
            error(`Invalid singleton kind '{ typeof(ty.Value) }'.`)
        end
    elseif ty.Kind == "List" then
        lists = { items = normalize_(ty.Items, inside) }
    elseif ty.Kind == "Function" then
        local params = table.create<<NormalizedType>>(#ty.Parameters)

        for i, param in ty.Parameters do
            params[i] = normalize_(param, inside)
        end

        functions = {
            components = {
                {
                    generics = ty.Generics,
                    parameters = params,
                    variadic = normalize_(ty.Variadic, inside),
                    returns = if ty.Returns then normalize_(ty.Returns, inside) else nil,
                },
            }
        }
    else
        if ty.Kind ~= "Negation" and ty.Kind ~= "Union" and ty.Kind ~= "Intersection" then
            unreachable(ty.Kind)
        end
    end

    local n: NormalizedType = {
        errors = errors,
        nils = nils,
        booleans = booleans,
        numbers = numbers,
        strings = strings,
        lists = lists,
        functions = functions,
        pending = pending,
    }

    if ty.Kind == "Negation" then
        n = negate(normalize_(ty.Negated, inside))
    elseif ty.Kind == "Union" then
        for _, component in ty.Components do
            n = union(n, normalize_(component, inside))
        end
    elseif ty.Kind == "Intersection" then
        n = normalizedUnknown()

        for _, component in ty.Components do
            n = intersect(n, normalize_(component, inside))
        end
    end

    n.aliasName = ty.AliasName
    inside[ty] = nil

    return n
end

local function normalize(ty: Type): NormalizedType
    return normalize_(ty, {})
end

local function simplify(ty: Type)
    return awn.normalizationToType(normalize(ty))
end

type RequiredBoundsChange =
    | {
          read Target: Type,
          read IntersectUpperWith: Type?,
          read UnionLowerWith: nil,
      }
    | {
          read Target: Type,
          read IntersectUpperWith: nil,
          read UnionLowerWith: Type?,
      }

type SubtypingVariance = "Covariant" | "Contravariant" | "Invariant"

type SubtypingResult =
    | {
        read holds: true,
        read errorSurpressed: nil,
        read failedPath: nil,
        -- Changes to free type bounds we need to make so that the relation holds.
        read requiredBoundsChanges: { read RequiredBoundsChange },
      }
    | {
        read holds: false,
        read errorSurpressed: boolean,
        read failedPath: string,
      }

local function subtypeSuccess(changes: { read RequiredBoundsChange }?, variance: SubtypingVariance?): SubtypingResult
    return {
        holds = true,
        variance = variance or "Covariant",
        requiredBoundsChanges = changes or {},
    }
end

-- TODO luau `surpressed` and `failed` being inferred as `unknown`?
local function subtypeFailure(surpressed: boolean, failed: string, variance: SubtypingVariance?): SubtypingResult
    return {
        holds = false,
        errorSurpressed = surpressed,
        variance = variance or "Covariant",
        failedPath = failed
    }
end

local function normalizedNil()
    return normalize(nilType)
end

local function normalizedBoolean(singleton: boolean?)
    return normalize(if singleton == nil then booleanType else singletonType(singleton))
end

local function normalizedString(singleton: string?)
    return normalize(if singleton == nil then stringType else singletonType(singleton))
end

local function checkBoundsConsistency(changes: { read RequiredBoundsChange }): { Type }
    local erroneousSet = {}
    local stored = {}

    for _, change in changes do
        assert(change.Target.Kind == "Free")

        local currently = stored[change.Target] or {
            upper = change.IntersectUpperWith or change.Target.UpperBound,
            lower = change.UnionLowerWith or change.Target.LowerBound,
        }

        if change.IntersectUpperWith then
            currently.upper = makeIntersection(currently.upper, change.IntersectUpperWith)
        else
            assert(change.UnionLowerWith)
            currently.lower = makeUnion(currently.lower, change.UnionLowerWith)
        end

        local consistencyResult = awn.isSubtypeOf(normalize(currently.lower), normalize(currently.upper))

        if not consistencyResult.holds then
            -- NOTE: Stringification won't have the actual bounds.
            log(`!!! Free type bounds mismatch for '{ awn.typeToString(change.Target) }': { consistencyResult.failedPath } !!!`)
            erroneousSet[change.Target] = true
        end

        stored[change.Target] = currently
    end

    local erroneous = {}
    for failed, _ in erroneousSet do
        table.insert(erroneous, failed)
    end

    return erroneous
end

local function applyBoundsChanges(changes: { read RequiredBoundsChange }): { Type }
    local erroneousSet = {}

    for _, change in changes do
        assert(change.Target.Kind == "Free")

        if change.IntersectUpperWith then
            change.Target.UpperBound = makeIntersection(change.Target.UpperBound, change.IntersectUpperWith)
        else
            assert(change.UnionLowerWith)
            change.Target.LowerBound = makeUnion(change.Target.LowerBound, change.UnionLowerWith)
        end

        local consistencyResult = awn.isSubtypeOf(normalize(change.Target.LowerBound), normalize(change.Target.UpperBound))

        if not consistencyResult.holds then
            log(`Free type bounds mismatch for '{ awn.typeToString(change.Target) }': { consistencyResult.failedPath }`)
            erroneousSet[change.Target] = true
        end
    end

    local erroneous = {}
    for failed, _ in erroneousSet do
        table.insert(erroneous, failed)
    end

    return erroneous
end

local function intersectApplicableReturns(components: { read NormalizedFunctionComponentType }, argument: NormalizedType): NormalizedType?
    local applicable = {}

    for _, c in components do
        local param = c.parameters[1] or c.variadic

        if #c.parameters <= 1 and c.returns then
            local result = awn.isSubtypeOf(argument, param)

            if result.holds then
                applyBoundsChanges(result.requiredBoundsChanges)
                table.insert(applicable, c.returns)
            end
        end
    end

    if #applicable == 0 then
        return nil
    end

    local returned = applicable[1]

    for i = 2, #applicable do
        returned = intersect(returned, applicable[i])
    end

    return returned
end

local function decomposeToSingletons(n: NormalizedType): { NormalizedType }?
    if n.numbers or n.strings.cofinite or n.lists or n.functions or n.pending then
        return nil
    end

    local singles = {}

    if n.nils then
        table.insert(singles, normalizedNil())
    end

    if n.booleans.hasTrue then
        table.insert(singles, normalizedBoolean(true))
    end

    if n.booleans.hasFalse then
        table.insert(singles, normalizedBoolean(false))
    end

    for s, _ in n.strings.singletons do
        table.insert(singles, normalizedString(s))
    end

    return singles
end

local function normalizationToString(n: NormalizedType, opts: { read DoNotTryNegating: boolean? }?): string
    return awn.typeToString(awn.normalizationToType(n), { DoNotTryNegating = if opts then opts.DoNotTryNegating else false })
end

local function normalizedFunctionComponentToString(nfc: NormalizedFunctionComponentType): string
    local gensStrings = table.create<<string>>(#nfc.generics)
    local paramStrings = table.create<<string>>(#nfc.parameters + 1)

    for i, gen in nfc.generics do
        gensStrings[i] = awn.typeToString(gen)
    end

    for i, param in nfc.parameters do
        paramStrings[i] = normalizationToString(param)
    end

    if not isNever(nfc.variadic) then
        paramStrings[#nfc.parameters + 1] = `...{ normalizationToString(nfc.variadic) }`
    end

    local str = `({ table.concat(paramStrings, ", ") }) -> { if nfc.returns then normalizationToString(nfc.returns) else "()" }`

    if #nfc.generics > 0 then
        str = `<{ table.concat(gensStrings, ", ") }>` .. str
    end

    return str
end

local function normalizedFunctionComponentToFunctionType(nfc: NormalizedFunctionComponentType): Type
    local parameters = table.create<<Type>>(#nfc.parameters)

    for i, param in nfc.parameters do
        parameters[i] = awn.normalizationToType(param)
    end

    return functionType(
        nfc.generics,
        parameters,
        awn.normalizationToType(nfc.variadic),
        if nfc.returns then awn.normalizationToType(nfc.returns) else nil
    )
end

function awn.isFunctionSubtypeOf(a: NormalizedFunctionType, b: NormalizedFunctionType): SubtypingResult
    -- `((A) -> B) & ((C) -> D) & ... <: function`
    if not b.components then
        return subtypeSuccess()
    end

    -- `function </: ((A) -> B) & ((C) -> D) & ...`
    if not a.components then
        return subtypeFailure(false, `Unexpected 'top' function type.`)
    end

    local requiredChanges = {}

    for i, cb in b.components do
        local singles = nil

        if #cb.parameters == 1 and isNever(cb.variadic) then
            singles = decomposeToSingletons(cb.parameters[1])
        end

        if singles then
            for _, single in singles do
                local car = intersectApplicableReturns(a.components, single)

                if not car then
                    return subtypeFailure(false, `No overload accepts '{ normalizationToString(single) }'.`)
                end

                if cb.returns then
                    local result = awn.isSubtypeOf(car, cb.returns)

                    if result.holds then
                        -- TODO luau cast.
                        table.move(result.requiredBoundsChanges, 1, #result.requiredBoundsChanges, #requiredChanges + 1, requiredChanges :: any)
                    else
                        return subtypeFailure(false, `With '{ normalizationToString(single) }': { result.failedPath }`)
                    end
                end
            end
        else
            local found = false
            local failed = {}

            for ica, ca in a.components do
                local signature = normalizedFunctionComponentToString(ca)

                if #ca.parameters ~= #cb.parameters and isNever(ca.variadic) then
                    table.insert(failed, `'{ signature }' has a differing number of parameters.`)
                    continue
                end

                local paramsMatched = true
                local instantiate = #ca.generics > 0
                local nonInstantiated = signature
                local instantiationFailed = false

                if instantiate then
                    local aFn = normalizedFunctionComponentToFunctionType(ca)
                    local bFn = normalizedFunctionComponentToFunctionType(cb)
                    local instantiated, erroneous, ftyToGeneric, bounds = awn.instantiateGenericsAtCallsite(aFn, bFn, false)
                    assert(bounds)

                    for _, free in erroneous do
                        local gen = ftyToGeneric[free]
                        local bound = bounds[free]
                        assert(bound)
                        assert(gen)
                        assert(free.Kind == "Free")

                        table.insert(
                            failed,
                            `'{ awn.typeToString(gen) }' would have to be a subtype of '{ awn.typeToString(bound.upper) }'`
                                .. ` while being called with '{ awn.typeToString(bound.lower) }'.`
                        )
                        instantiationFailed = true
                    end

                    local instantiatedNorm = normalize(instantiated)
                    assert(instantiatedNorm.functions and instantiatedNorm.functions.components and #instantiatedNorm.functions.components > 0)

                    ca = instantiatedNorm.functions.components[1]
                    -- TODO luau `ca` becoming `any` after this line
                    signature = normalizedFunctionComponentToString(ca)
                    ca = ca :: NormalizedFunctionComponentType
                end

                if instantiationFailed then
                    continue
                end

                for i, bParam in cb.parameters do
                    local param = ca.parameters[i] or ca.variadic
                    local paramResult = awn.isSupertypeOf(param, bParam)

                    if paramResult.holds then
                        -- TODO luau cast.
                        table.move(paramResult.requiredBoundsChanges, 1, #paramResult.requiredBoundsChanges, #requiredChanges + 1, requiredChanges :: any)
                    else
                        local paramStr = normalizationToString(cb.parameters[i])
                        table.insert(
                            failed,
                            `'{ signature }'{ if instantiate then " (instantiation of '" .. nonInstantiated .. "')" else "" }`
                                .. ` does not accept parameter #{ i } '{ paramStr }': { paramResult.failedPath }`
                        )

                        paramsMatched = false
                    end
                end

                if #cb.parameters == 0 then
                    local variadicResult = awn.isSupertypeOf(ca.variadic, cb.variadic)

                    if variadicResult.holds then
                        -- TODO luau cast.
                        table.move(variadicResult.requiredBoundsChanges, 1, #variadicResult.requiredBoundsChanges, #requiredChanges + 1, requiredChanges :: any)
                    else
                        local paramStr = normalizationToString(cb.variadic)
                        table.insert(
                            failed,
                            `'{ signature }'{ if instantiate then " (instantiation of '" .. nonInstantiated .. "')" else "" }`
                                .. ` does not accept variadics '...{ paramStr }': { variadicResult.failedPath }`
                        )

                        paramsMatched = false
                    end
                end

                if not paramsMatched then
                    continue
                end

                if ca.returns and cb.returns then
                    local returnResult = awn.isSubtypeOf(ca.returns, cb.returns)

                    if returnResult.holds then
                        -- TODO luau cast.
                        table.move(returnResult.requiredBoundsChanges, 1, #returnResult.requiredBoundsChanges, #requiredChanges + 1, requiredChanges :: any)
                    else
                        table.insert(
                            failed,
                            `'{ signature }'{ if instantiate then " (instantiation of '" .. nonInstantiated .. "')" else "" } does not return '{ normalizationToString(cb.returns) }'.`
                        )
                        continue
                    end
                end

                found = true
                break
            end

            if not found then
                local paramStrings = table.create<<string>>(#cb.parameters)

                for i, param in cb.parameters do
                    paramStrings[i] = normalizationToString(param)
                end

                local signature = `({ table.concat(paramStrings, ", ") }) -> { if cb.returns then normalizationToString(cb.returns) else "()" }`

                if #b.components > 1 then
                    return subtypeFailure(false, `No compatible overload was found for #{ i } '{ signature }':\n* { table.concat(failed, "\n* ") }`)
                else
                    return subtypeFailure(false, `\n* { table.concat(failed, "\n* ") }`)
                end
            end
        end
    end

    return subtypeSuccess(requiredChanges)
end

local function freeTypesOf(n: NormalizedType): { Type }?
    if not n.pending then
        return nil
    end

    local frees = {}

    for ty, _ in n.pending do
        if ty.Kind == "Free" then
            table.insert(frees, ty)
        end
    end

    if #frees > 0 then
        return frees
    else
        return nil
    end
end

local function isSubtypeOf(a: NormalizedType, b: NormalizedType): SubtypingResult
    -- `unknown` is not a useful narrowing of an upper bound.
    if isUnknown(b) then
        return subtypeSuccess()
    end

    local aFrees = freeTypesOf(a)
    if aFrees then
        -- TODO luau removing annotation causes read-write indexer mismatch error
        local changes: { RequiredBoundsChange } = {}

        for _, free in aFrees do
            table.insert(changes, {
                Target = free,
                IntersectUpperWith = awn.normalizationToType(b),
            })
        end

        return subtypeSuccess(changes)
    end

    local surpressed = a.errors or b.errors

    -- `never` is a proper narrowing, that's why we want to handle it before hitting this early-out.
    if isNever(b) and not isNever(a) then
        return subtypeFailure(surpressed, "Nothing is a subtype of `never` except `never` itself.")
    end

    local bFrees = freeTypesOf(b)
    if bFrees then
        local changes: { RequiredBoundsChange } = {}

        for _, free in bFrees do
            table.insert(changes, {
                Target = free,
                UnionLowerWith = awn.normalizationToType(a),
            })
        end

        return subtypeSuccess(changes)
    end

    if a.nils and not b.nils then
        return subtypeFailure(surpressed, "Unexpected `nil`.")
    end

    if a.booleans.hasTrue and not b.booleans.hasTrue then
        return subtypeFailure(surpressed, "Unexpected `true`.")
    elseif a.booleans.hasFalse and not b.booleans.hasFalse then
        return subtypeFailure(surpressed, "Unexpected `false`.")
    end

    if a.numbers and not b.numbers then
        return subtypeFailure(surpressed, "Unexpected `number`.")
    end

    -- `string </: "a" | "b" | ...`
    if a.strings.cofinite and not b.strings.cofinite then
        return subtypeFailure(surpressed, "Unexpected `string`.")
    elseif not a.strings.cofinite and b.strings.cofinite then
        for s, _ in a.strings.singletons do
            if b.strings.singletons[s] then
                return subtypeFailure(surpressed, `\`"{ s }"\` was excluded.`)
            end
        end
    elseif a.strings.cofinite and b.strings.cofinite then
        for s, _ in b.strings.singletons do
            if not a.strings.singletons[s] then
                return subtypeFailure(surpressed, `Missing negation \`"{ s }"\``)
            end
        end
    elseif not a.strings.cofinite and not b.strings.cofinite then
        for s, _ in a.strings.singletons do
            if not b.strings.singletons[s] then
                return subtypeFailure(surpressed, `Unexpected \`"{ s }"\``)
            end
        end
    end

    local requiredChanges = {}

    if a.lists and not b.lists then
        return subtypeFailure(surpressed, `Unexpected list.`)
    -- `list </: { T }
    elseif a.lists and not a.lists.items and b.lists and b.lists.items then
        return subtypeFailure(surpressed, `'list' top type is not a subtype of any '\{ T }' type.`)
    elseif a.lists and a.lists.items and b.lists and b.lists.items then
        -- Check invariantly.
        -- `T <: U && U <: T` is equivalent to `T == U`.
        local aItems = a.lists.items
        local bItems = b.lists.items

        local result = awn.isExactly(aItems, bItems)

        if not result.holds then
            return result
        end

        requiredChanges = result.requiredBoundsChanges
    end

    if a.functions and not b.functions then
        return subtypeFailure(surpressed, "Unexpected function.")
    -- `function </: ((A) -> B) & ((C) -> D) & ...`
    elseif a.functions and b.functions then
        local result = awn.isFunctionSubtypeOf(a.functions, b.functions)

        if result.holds then
            table.move(result.requiredBoundsChanges, 1, #result.requiredBoundsChanges, #requiredChanges + 1, requiredChanges)
        else
            return subtypeFailure(surpressed, result.failedPath)
        end
    end

    if a.pending then
        for ty, upperBound in a.pending do
            local otherBound = b.pending and b.pending[ty]
            local upperBoundResult

            if otherBound then
                upperBoundResult = isSubtypeOf(upperBound, otherBound)
            else
                upperBoundResult = isSubtypeOf(upperBound, b)
            end

            if not upperBoundResult.holds then
                return subtypeFailure(surpressed, `Unexpected \`{ awn.typeToString(ty) }{ if isUnknown(upperBound) then "" else " & " .. normalizationToString(upperBound) }\`.`)
            end
        end
    end

    return subtypeSuccess(requiredChanges)
end

local function isSupertypeOf(a: NormalizedType, b: NormalizedType): SubtypingResult
    local result = isSubtypeOf(b, a)
    -- result.Variance = "Contravariant"

    return result
end

local function isExactly(a: NormalizedType, b: NormalizedType): SubtypingResult
    local r1 = isSubtypeOf(a, b)

    if not r1.holds then
        return r1
    end

    local r2 = isSubtypeOf(b, a)

    if not r2.holds then
        return r2
    end

    local boundsChanges = {}
    -- TODO luau cast.
    table.move(r1.requiredBoundsChanges :: any, 1, #r1.requiredBoundsChanges, 1, boundsChanges)
    table.move(r2.requiredBoundsChanges :: any, 1, #r2.requiredBoundsChanges, #boundsChanges + 1, boundsChanges)

    return {
        holds = true,
        errorSurpressed = r1.errorSurpressed or r2.errorSurpressed,
        requiredBoundsChanges = boundsChanges,
    }
end

local genericTypeNameCount = 0
local freeTypeNameCount = 0
local typeEnv: { read [string]: Type? }
local localTypeEnv: { [string]: Type? } = {}

type ToStringOptions = {
    read Alias: string?,
    read HideFreeTypeBounds: boolean?,
    read DoNotTryNegating: boolean?,
}

type ToStringState = {
    options: ToStringOptions,
    assignedNames: { [Type]: string? },
    recursiveTypeCount: number,
    inside: { [Type]: true? },
    recursive: { [Type]: string? },
    currentlyRecursing: Type?,
}

local function typeToString_(ty: Type, state: ToStringState): string
    local opts = state.options

    if state.currentlyRecursing ~= ty then
        local rec = state.recursive[ty]
        if rec then
            return rec
        end

        if state.inside[ty] then
            state.recursiveTypeCount += 1

            local name = ty.AliasName or `t{ state.recursiveTypeCount }`
            state.recursive[ty] = name

            return name
        end
    end

    state.currentlyRecursing = nil
    state.inside[ty] = true
    local str

    local function genericTypeName(tyvar: Type)
        assert(tyvar.Kind == "Generic")
        local already = tyvar.Name or state.assignedNames[tyvar]

        if already then
            return already
        else
            local name = string.char((genericTypeNameCount + 19) % 26 + 65)

            if genericTypeNameCount > 25 then
                name ..= genericTypeNameCount // 25 + 1
            end

            while typeEnv[name] do
                genericTypeNameCount += 1
                name = string.char((genericTypeNameCount + 19) % 26 + 65)

                if genericTypeNameCount > 25 then
                    name ..= genericTypeNameCount // 25 + 1
                end
            end

            state.assignedNames[tyvar] = name
            genericTypeNameCount += 1

            return name
        end
    end

    local function freeTypeName(tyvar: Type)
        assert(tyvar.Kind == "Free")
        local already = state.assignedNames[tyvar]

        if already then
            return already
        else
            local name = `'{ string.char(freeTypeNameCount % 26 + 97) }`

            if freeTypeNameCount > 25 then
                name ..= freeTypeNameCount // 25 + 1
            end

            state.assignedNames[tyvar] = name
            freeTypeNameCount += 1

            return name
        end
    end

    if ty.AliasName and ty.AliasName ~= opts.Alias then
        str = ty.AliasName
    elseif ty.Kind == "error" then
        str = "*error*"
    elseif ty.Kind == "never" then
        str = "never"
    elseif ty.Kind == "unknown" then
        str = "unknown"
    elseif ty.Kind == "Primitive" then
        str = ty.Primitive
    elseif ty.Kind == "List" then
        str = `\{ { typeToString_(ty.Items, state) } }`
    elseif ty.Kind == "Singleton" then
        if typeof(ty.Value) == "string" then
            str = `"{ ty.Value }"`
        else
            str = tostring(ty.Value)
        end
    elseif ty.Kind == "Generic" then
        str = genericTypeName(ty)
    elseif ty.Kind == "Function" then
        str = ""

        if #ty.Generics > 0 then
            local gens = table.create<<string>>(#ty.Generics)

            for i, gen in ty.Generics do
                gens[i] = typeToString_(gen, state)
            end

            str = `<{ table.concat(gens, ", ") }>`
        end

        local params = table.create<<string>>(#ty.Parameters + 1)

        for i, param in ty.Parameters do
            params[i] = typeToString_(param, state)
        end

        if ty.Variadic.Kind ~= "never" then
            table.insert(params, `...{ typeToString_(ty.Variadic, state) }`)
        end

        str ..= `({ table.concat(params, ", ") }) -> `
        str ..= if ty.Returns then typeToString_(ty.Returns, state) else "()"

    elseif ty.Kind == "PendingExpansion" then
        local arguments = table.create<<string>>(#ty.Arguments)

        for i, a in ty.Arguments do
            arguments[i] = typeToString_(a, state)
        end

        str = `{ ty.Name }<{ table.concat(arguments, ", ") }>`

    elseif ty.Kind == "Negation" then
        local inner = typeToString_(ty.Negated, state)

        if ty.Negated.Kind == "Union" or ty.Negated.Kind == "Intersection" then
            str = `~({ inner })`
        else
            str = `~{ inner }`
        end

    elseif ty.Kind == "Union" then
        local tys = table.create<<string>>(#ty.Components)
        local length = 0

        for i, c in ty.Components do
            local ts = typeToString_(c, state)
            length += #ts

            if c.Kind == "Union" or c.Kind == "Intersection" then
                tys[i] = `({ ts })`
            else
                tys[i] = ts
            end
        end

        str = table.concat(tys, if length < 24 then " | " else "\n  | ")

    elseif ty.Kind == "Intersection" then
        local tys = table.create<<string>>(#ty.Components)
        local length = 0

        for i, c in ty.Components do
            local ts = typeToString_(c, state)
            length += #ts

            if c.Kind == "Union" or c.Kind == "Intersection" then
                tys[i] = `({ ts })`
            else
                tys[i] = ts
            end
        end

        str = table.concat(tys, if length < 24 then " & " else "\n  & ")

    elseif ty.Kind == "Free" then
        str = freeTypeName(ty)

        if not opts.HideFreeTypeBounds then
            local showedBounds = false

            if ty.UpperBound.Kind ~= "unknown" then
                str ..= ` <: { typeToString_(ty.UpperBound, state) }`
                showedBounds = true
            end

            if ty.LowerBound.Kind ~= "never" then
                str = `{ typeToString_(ty.LowerBound, state) } <: ` .. str
                showedBounds = true
            end

            if showedBounds then
                str = `({ str })`
            end
        end
    else
        unreachable(ty.Kind)
        error(`Unreachable.`)
    end

    state.inside[ty] = nil
    return str
end

local loggingAssignedNames = {}

local function typeToString_inner(ty, tsopts: ToStringOptions?)
    if not logInference then
        genericTypeNameCount = 0
        freeTypeNameCount = 0
    end

    local opts: ToStringOptions = tsopts or {}
    local state: ToStringState = {
        options = opts,
        assignedNames = if logInference then loggingAssignedNames else {},
        recursiveTypeCount = 0,
        inside = {},
        recursive = {},
        currentlyRecursing = nil,
    }

    typeToString_(ty, state)
    local str = typeToString_(ty, state)

    if next(state.recursive) ~= nil then
        state.recursiveTypeCount = -math.huge
        local onNewlines = false
        local wheres = {}

        for ty, name in state.recursive do
            state.currentlyRecursing = ty
            local where = typeToString_(ty, state)

            if #where > 32 then
                onNewlines = true
            end

            table.insert(wheres, `where { name } = { where }`)
        end

        if onNewlines then
            str ..= `\n{ table.concat(wheres, "\n") }`
        else
            str ..= " " .. table.concat(wheres, "\n")
        end
    end

    return str
end

local tryNegationInStringification = true

local function typeToString(ty, tsopts: ToStringOptions?)
    local normalString = typeToString_inner(ty, tsopts)

    if tryNegationInStringification and (not tsopts or not tsopts.DoNotTryNegating) then
        local norm = normalize(ty)
        if not isUnknown(norm) and not hasNonNegatables(norm) then
            local negated = negate(norm)

            local normToType = awn.normalizationToType(negated)
            local negatedString = typeToString(negationType(normToType), { DoNotTryNegating = true })

            if #negatedString < #normalString then
                return negatedString
            end
        end
    end

    return normalString
end

local function normalizationToType(n: NormalizedType): Type
    local t: { Type } = {}

    if n.errors then
        table.insert(t, errorType)
    end

    if isUnknown(n) then
        table.insert(t, unknownType)
    else
        if n.nils then
            table.insert(t, nilType)
        end

        if n.booleans.hasTrue and n.booleans.hasFalse then
            table.insert(t, booleanType)
        elseif n.booleans.hasTrue then
            table.insert(t, singletonType(true))
        elseif n.booleans.hasFalse then
            table.insert(t, singletonType(false))
        end

        if n.numbers then
            table.insert(t, numberType)
        end

        if isStringTop(n.strings) then
            table.insert(t, stringType)
        elseif not isStringNever(n.strings) then
            local strs: { Type } = {}

            for s, _ in n.strings.singletons do
                local sty = singletonType(s)

                if n.strings.cofinite then
                    table.insert(strs, negationType(sty))
                else
                    table.insert(strs, sty)
                end
            end

            if n.strings.cofinite then
                table.insert(strs, 1, stringType)
                table.insert(t, intersectionType(strs))
            else
                if #strs == 1 then
                    table.insert(t, strs[1])
                else
                    table.insert(t, unionType(strs))
                end
            end
        end

        if n.lists then
            if n.lists.items then
                table.insert(t, listType(normalizationToType(n.lists.items)))
            else
                table.insert(t, topListType)
            end
        end

        if n.functions then
            if n.functions.components then
                local cs = table.create<<Type>>(#n.functions.components)

                for i, f in n.functions.components do
                    local params = table.create<<Type>>(#f.parameters)

                    for i, param in f.parameters do
                        params[i] = normalizationToType(param)
                    end

                    cs[i] = functionType(f.generics, params, normalizationToType(f.variadic), if f.returns then normalizationToType(f.returns) else nil)
                end

                if #cs == 1 then
                    table.insert(t, cs[1])
                else
                    table.insert(t, intersectionType(cs))
                end
            else
                table.insert(t, topFunctionType)
            end
        end

        if n.pending then
            local pends = {}

            for ty, inter in n.pending do
                if isUnknown(inter) then
                    table.insert(pends, ty)
                else
                    table.insert(pends, intersectionType({ ty, normalizationToType(inter) }))
                end
            end

            if #pends == 1 then
                table.insert(t, pends[1])
            else
                table.insert(t, unionType(pends))
            end
        end
    end

    if #t == 0 then
        local ty = table.clone(neverType)
        ty.AliasName = n.aliasName

        return ty

    elseif #t == 1 then
        local ty = t[1]

        if ty.Kind ~= "Primitive" and ty.Kind ~= "never" and ty.Kind ~= "unknown" and ty.Kind ~= "Generic" and ty.Kind ~= "Free" then
            ty = table.clone(ty)
            ty.AliasName = n.aliasName
        end

        return ty
    end

    local ty = unionType(t)
    ty.AliasName = n.aliasName

    return ty
end

-- Maps type names to types.
typeEnv = {
    never = neverType,
    unknown = unknownType,
    ["nil"] = nilType,
    boolean = booleanType,
    number = numberType,
    string = stringType,
}
-- Maps declaration names to types.
local typeAssociations: { read [string]: { Expression: caw.Expression?, Type: Type }? } = {
    valuenever = {
        Type = neverType
    },

    print = {
        Type = functionType({}, { unknownType }, unknownType),
    },
    tostring = {
        Type = functionType({}, { unknownType }, neverType, stringType),
    }
}

local localTypeAssociations: { [string]: { Expression: caw.Expression, Type: Type }? } = {}

-- The generics that a type alias is parameterized over.
local typeEnvGenericParameters: { [Type]: { read Type }? } = {}
local typeEnvOrdered: { string } = {}
local typeAssociationsOrdered = {}

-- `Sub <: Super`. Can modify bounds of either if either are Free.
-- Returns the list of free types with erroneous bounds, if there were any.
local function subtypingRelation(sub: Type, super: Type, applyBounds: boolean?): ({ Type }, { read RequiredBoundsChange })
    log(`Relation: '{ typeToString(sub) }' <: '{ typeToString(super) }'`)

    sub, super = awn.reduceTypeFunctions(sub), awn.reduceTypeFunctions(super)
    local result = isSubtypeOf(normalize(sub), normalize(assert(super))) -- TODO luau assert

    if result.holds then
        if applyBounds ~= false then
            return applyBoundsChanges(result.requiredBoundsChanges), result.requiredBoundsChanges
        else
            return checkBoundsConsistency(result.requiredBoundsChanges), result.requiredBoundsChanges
        end
    else
        return {}, {}
    end
end

-- `subtypingRelation`, but report error if relation does not hold.
local function constrainSubtype(state: InferenceState, position: caw.Position, sub: Type, super: Type)
    log(`{ position.Line }:{ position.Column }: Constraining:`)
    sub, super = awn.reduceTypeFunctions(sub), awn.reduceTypeFunctions(super)

    local erroneous = subtypingRelation(sub, assert(super)) -- TODO luau assert.

    for _, free in erroneous do
        assert(free.Kind == "Free")
        table.insert(typeErrors, `Internal error: { typeToString(free) } has incompatible bounds: { typeToString(awn.simplify(free.LowerBound)) } </: { typeToString(awn.simplify(free.UpperBound)) }`)
    end

    awn.check(sub, assert(super), position) -- TODO luau assert.

    log("")
end

type SubstitutionState = {
    substitutions: { read [Type]: Type? },
    traversed: { [Type]: true? },
    inside: { [Type]: true? },
}

local function substituteAllIn_(ty: Type, state: SubstitutionState): Type
    if state.inside[ty] then
        errorReport(
            `Encountered recursive type '{ typeToString(ty) }' unexpectedly, inference result may be incorrect.`,
            { Line = 1, Column = 1, Offset = 1 }
        )
        return ty
    end
    state.inside[ty] = true

    local fullSub = state.substitutions[ty]
    if fullSub then
        fullSub = if fullSub ~= ty then substituteAllIn_(fullSub, state) else fullSub
        state.inside[ty] = nil

        return fullSub
    end

    local replacement = ty

    if ty.Kind == "error" or ty.Kind == "never" or ty.Kind == "unknown"
        or ty.Kind == "Primitive" or ty.Kind == "Singleton" or ty.Kind == "Generic"
        or ty.Kind == "Free"
    then
        replacement = ty
    elseif ty.Kind == "List" then
        replacement = listType(substituteAllIn_(ty.Items, state))
    elseif ty.Kind == "Function" then
        local params = table.create<<Type>>(#ty.Parameters)

        for i, param in ty.Parameters do
            params[i] = substituteAllIn_(param, state)
        end

        local rets = if ty.Returns then substituteAllIn_(ty.Returns, state) else nil
        replacement = functionType(ty.Generics, params, substituteAllIn_(ty.Variadic, state), rets)

    elseif ty.Kind == "Negation" then
        replacement = negationType(substituteAllIn_(ty.Negated, state))

    elseif ty.Kind == "Union" then
        local components = table.create<<Type>>(#ty.Components)

        for i, c in ty.Components do
            components[i] = substituteAllIn_(c, state)
        end

        replacement = unionType(components)

    elseif ty.Kind == "Intersection" then
        local components = table.create<<Type>>(#ty.Components)

        for i, c in ty.Components do
            components[i] = substituteAllIn_(c, state)
        end

        replacement = intersectionType(components)

    elseif ty.Kind == "PendingExpansion" then
        local arguments = table.create<<Type>>(#ty.Arguments)

        for i, a in ty.Arguments do
            arguments[i] = substituteAllIn_(a, state)
        end

        replacement = pendingExpansionType(ty.Name, arguments)
    else
        unreachable(ty.Kind)
        error(`Unreachable.`)
    end

    state.traversed[replacement] = true
    state.traversed[ty] = true

    state.inside[ty] = nil
    return replacement
end

local function substituteAllIn(ty: Type, substitutions: { read [Type]: Type? }): Type
    return substituteAllIn_(ty, {
        substitutions = substitutions,
        traversed = {},
        inside = {},
    })
end

type FreeTypeSubstitution = {
    Polarity: Polarity,
    With: Type,
}

type GatherFreeTypeSubstitutionsOptions = {
    read expression: caw.Expression?,
    read polarity: Polarity,
    read alwaysConcretize: boolean,
    read bounds: { read [Type]: { read upper: Type, read lower: Type }? }?,
}

type GatherFreeTypeSubstitutionsState = {
    options: GatherFreeTypeSubstitutionsOptions,
    substitutions: { [Type]: Type },
    generics: { Type },

    polarities: { [Type]: Polarity },
    polarity: Polarity,
    inside: { [Type]: true? },
}

local function cleanSubstitution(ty: Type, sub: Type)
    if sub.Kind == "Free" then
        local here = sub
        local inside: { [Type]: true? } = {}

        repeat
            inside[here] = true
            here = here.UpperBound

            if inside[here] then
                sub = unknownType
                break
            end
        until here.Kind ~= "Free"
    end

    return sub
end

local function gatherFreeTypeSubstitutions_(state: GatherFreeTypeSubstitutionsState, ty: Type, name: string)
    local opts = state.options

    if state.inside[ty] then
        return
    end
    state.inside[ty] = true

    if ty.Kind == "Free" then
        local upper = ty.UpperBound
        local lower = ty.LowerBound

        if opts.bounds then
            local overwritten = opts.bounds[ty]
            if overwritten then
                upper = overwritten.upper
                lower = overwritten.lower
            end
        end

        local previous = state.substitutions[ty]

        if previous and not opts.alwaysConcretize then
            local prevPolarity = assert(state.polarities[ty])

            if prevPolarity == state.polarity then
                -- Already all ok.
            else
                local normUpper = normalize(upper)
                local replacement = nil

                if prevPolarity == "Mixed" then
                    -- The previous polarity was already `Mixed`. Because we don't support generic bounds,
                    -- set the replacement type to just the constraint.

                    if isUnknown(normUpper) then
                        -- If there's no constraint, generalize.
                        replacement = genericType()
                        table.insert(state.generics, replacement)
                    else
                        -- TODO add explanatory snippet for this branch...
                        log(`{ typeToString(ty, { HideFreeTypeBounds = true }) } upper bound '{ typeToString(upper) }' will be clipped for intersection with '{ typeToString(previous) }'`)

                        normUpper = intersect(normUpper, normalize(previous))
                        replacement = normalizationToType(normUpper)
                    end
                else
                    -- Again, as we don't support generic bounds yet, just set the replacement to the upper bound if there is one.
                    if isUnknown(normUpper) then
                        replacement = genericType()
                        table.insert(state.generics, replacement)
                    else
                        log(`{ typeToString(ty, { HideFreeTypeBounds = true }) } will be clipped to its upper bound '{ typeToString(upper) }' even though it appears in an invariant position`)

                        replacement = upper
                    end
                end

                replacement = cleanSubstitution(ty, replacement)
                state.substitutions[ty] = replacement
                state.polarities[ty] = "Mixed"
            end

            state.inside[ty] = nil
            return
        end

        if state.polarity ~= "Positive" and isNever(normalize(upper)) then
            -- No source expression = don't report.
            if opts.expression then
                local nameCorrected = string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2, #name)
                errorReport(`{ nameCorrected } has been reduced to never, this function is not callable with any value.`, opts.expression.Position)

                state.substitutions[ty] = neverType
            end
        else
            local sub = if state.polarity == "Positive" then lower else upper

            --[=[
            -- TODO

            Consider:

            function f(x, y)
                x = y
                y = x
                return x
            end

            With the current code, the result is:

            f: (t1, ('b <: t1)) -> t1
            where t1 = ('a <: ('b <: t1))

            if sub.Kind == "Free" then
                gatherFreeTypeSubstitutions_(state, sub, name)

                if state.Substitutions[sub] and state.Substitutions[sub] ~= ty then
                    gatherFreeTypeSubstitutions_(state, state.Substitutions[sub], name)
                    state.Substitutions[sub] = state.Substitutions[state.Substitutions[sub]]
                end

                if state.Substitutions[sub] == ty then
                    if state.Polarity == "Positive" then
                        sub = neverType
                    else
                        sub = unknownType
                    end
                end
            end
            ]=]--

            -- TODO: If we don't do this, then generics are left as free types in implicit instantiations at call sites.
            if not previous or not opts.alwaysConcretize or sub.Kind ~= "Free" then
                state.substitutions[ty] = cleanSubstitution(ty, sub)
            else
                log(`Discarding substitution { typeToString(sub) } for { typeToString(ty) } ({ state.polarity }) because { typeToString(previous) } was already set`)
            end

            log(`{ state.polarity } { typeToString(ty) } => { typeToString(state.substitutions[ty]) }`)
        end

        state.polarities[ty] = state.polarity

        gatherFreeTypeSubstitutions_(state, upper, name)
        gatherFreeTypeSubstitutions_(state, lower, `lower bound of { name }`)

    elseif ty.Kind == "List" then
        local prevPolarity = state.polarity

        -- Lists are invariant. Force it to be generic.
        state.polarity = "Negative"
        gatherFreeTypeSubstitutions_(state, ty.Items, name .. "[X]")

        state.polarity = "Positive"
        gatherFreeTypeSubstitutions_(state, ty.Items, name .. "[X]")

        state.polarity = prevPolarity

    elseif ty.Kind == "Function" then
        local prevPolarity = state.polarity
        state.polarity = "Positive"

        for i, param in ty.Parameters do
            gatherFreeTypeSubstitutions_(state, param, `parameter { i } of { name }`)
        end

        gatherFreeTypeSubstitutions_(state, ty.Variadic, `variadic argument type of { name }`)

        if ty.Returns then
            state.polarity = "Negative"
            gatherFreeTypeSubstitutions_(state, ty.Returns, `return type of { name }`)
        end

        state.polarity = prevPolarity

    elseif ty.Kind == "Union" or ty.Kind == "Intersection" then
        for i, c in (ty :: UnionType | IntersectionType).Components do -- TODO luau cast.
            gatherFreeTypeSubstitutions_(state, c, `a component of the { string.lower(ty.Kind) } of { name }`)
        end
    elseif ty.Kind == "Negation" then
        gatherFreeTypeSubstitutions_(state, ty.Negated, `negation of { name }`)
    elseif ty.Kind == "PendingExpansion" then
        local prevPolarity = state.polarity

        state.polarity = "Positive"
        for i, argument in ty.Arguments do
            gatherFreeTypeSubstitutions_(state, argument, `argument #{ i } of { name }`)
        end

        state.polarity = "Negative"
        for i, argument in ty.Arguments do
            gatherFreeTypeSubstitutions_(state, argument, `argument #{ i } of { name }`)
        end

        state.polarity = prevPolarity
    elseif ty.Kind == "unknown" or ty.Kind == "never" or ty.Kind == "error" or ty.Kind == "Primitive"
        or ty.Kind == "Generic" or ty.Kind == "Singleton"
    then
        -- Nothing.
    else
        unreachable(ty.Kind)
    end

    state.inside[ty] = nil
end

local function gatherFreeTypeSubstitutions(opts: GatherFreeTypeSubstitutionsOptions, ty: Type, name: string)
    local state: GatherFreeTypeSubstitutionsState = {
        options = opts,
        substitutions = {},
        generics = {},

        polarities = {},
        polarity = opts.polarity,
        inside = {},
    }

    gatherFreeTypeSubstitutions_(state, ty, name)
    assert(next(state.inside) == nil)
    return state
end

type InferenceState = {
    Variadic: Type?,
    -- `true` = We're inferring a return type, but we haven't come across a `return` yet.
    -- `false`= Function is explicitly annotated as returning no value.
    -- `Type` = `FreeType`: We're currently inferring a return type.
    -- `Type` = Other: The return type was explicitly annotated.
    ReturnType: nil | Type | boolean,
}

local function instantiateGenericsAtCallsite(fn: Type, callsite: Type, applyBounds: boolean?): (Type, { Type }, { [Type]: Type }, { [Type]: { upper: Type, lower: Type } }?)
    local initialFn = fn
    log(`Trying to instantiate '{ typeToString(initialFn) }' with '{ typeToString(callsite) }'`)

    local gensToSubstitute = {}
    local ftyToGeneric = {}
    log("Generic substitutions:")

    if fn.Kind == "Function" then
        for _, gen in fn.Generics do
            local free = freeType()
            gensToSubstitute[gen] = free
            ftyToGeneric[free] = gen

            log(`* { typeToString(gen) } => { typeToString(free) }`)
        end

        log("")

        fn = functionType({}, fn.Parameters, fn.Variadic, fn.Returns)
        fn = substituteAllIn(fn, gensToSubstitute, {})
    end

    local erroneous, boundsChanges = subtypingRelation(fn, callsite, applyBounds)
    local bounds: { [Type]: { upper: Type, lower: Type } }? = nil

    if applyBounds == false then
        local nowBounds = {}

        for _, change in boundsChanges do
            assert(change.Target.Kind == "Free")

            local bound = nowBounds[change.Target] or {
                upper = change.Target.UpperBound,
                lower = change.Target.LowerBound,
            }

            if change.IntersectUpperWith then
                bound.upper = makeIntersection(bound.upper, change.IntersectUpperWith)
            else
                assert(change.UnionLowerWith)
                bound.lower = makeUnion(bound.lower, change.UnionLowerWith)
            end

            nowBounds[change.Target] = bound
        end

        bounds = nowBounds
    else
        bounds = nil
    end

    local concretizationResult = gatherFreeTypeSubstitutions(
        {
            polarity = "Negative",
            alwaysConcretize = true,
            bounds = bounds,
        },
        fn,
        "function call"
    )

    if logInference then
        log(`Implicit generic instantiations:`)
        for gen, ty in concretizationResult.substitutions do
            log(`* { typeToString(gen) } => { typeToString(ty) }`)
        end
        log("")
    end

    if #concretizationResult.generics > 0 then
        log(`Internal error: introduced generics while concretizing '{ typeToString(fn) }' with '{ typeToString(callsite) }'`)
    end

    local instantiation = awn.reduceTypeFunctions(substituteAllIn(fn, concretizationResult.substitutions, {}))
    log(`Instantiation: '{ typeToString(initialFn) }' ~ '{ typeToString(callsite) }' => '{ typeToString(instantiation) }'{ if #erroneous > 0 then " (**erroneous**)" else "" }\n`)

    return instantiation, erroneous, ftyToGeneric, bounds
end

local function typeAnnotationToType_(position: caw.Position, annotation: caw.TypeAnnotation): Type
    if annotation.Kind == "Error" then
        return table.clone(errorType) -- For alias names.

    elseif annotation.Kind == "Unit" then
        return errorReport(`'()' is only valid as a function return type annotation.`, position)

    elseif annotation.Kind == "Reference" then
        local ty = typeEnv[annotation.Reference] or localTypeEnv[annotation.Reference]

        if ty then
            if typeEnvGenericParameters[ty] then
                return errorReport(`'{ annotation.Reference }' requires type arguments.`, position)
            else
                if ty.Kind ~= "Generic" and ty.Kind ~= "Free" then
                    return table.clone(ty) -- For alias names.
                else
                    return ty
                end
            end
        else
            return errorReport(`Unknown type '{ annotation.Reference }'.`, position)
        end
    elseif annotation.Kind == "List" then
        return listType(typeAnnotationToType_(position, annotation.Items))

    elseif annotation.Kind == "Singleton" then
        return singletonType(annotation.Value)

    elseif annotation.Kind == "Generic" then
        local genTy = genericType(annotation.Name)

        typeEnv[annotation.Name] = genTy
        return genTy

    elseif annotation.Kind == "Function" then
        local gens = table.create<<Type>>(#annotation.Generics)

        for i, gen in annotation.Generics do
            gens[i] = typeAnnotationToType_(position, gen)
        end

        local params = table.create<<Type>>(#annotation.Parameters)
        local variadic = if annotation.Variadic then typeAnnotationToType_(position, annotation.Variadic) else neverType

        for i, param in annotation.Parameters do
            params[i] = typeAnnotationToType_(position, param)
        end

        return functionType(gens, params, variadic, if annotation.Returns then typeAnnotationToType_(position, annotation.Returns) else nil)

    elseif annotation.Kind == "AliasInstantiation" then
        local arguments = table.create<<Type>>(#annotation.Arguments)

        for i, a in annotation.Arguments do
            arguments[i] = typeAnnotationToType_(position, a)
        end

        return pendingExpansionType(annotation.Name, arguments)

    elseif annotation.Kind == "Negation" then
        return negationType(typeAnnotationToType_(position, annotation.Negated))

    elseif annotation.Kind == "Union" then
        local components = table.create<<Type>>(#annotation.Components)

        for i, c in annotation.Components do
            components[i] = typeAnnotationToType_(position, c)
        end

        return unionType(components)

    elseif annotation.Kind == "Intersection" then
        local components = table.create<<Type>>(#annotation.Components)

        for i, c in annotation.Components do
            components[i] = typeAnnotationToType_(position, c)
        end

        return intersectionType(components)
    elseif annotation.Kind == "Variadic" then
        return errorReport(`Internal error: Unexpected '...'.`, position)
    else
        unreachable(annotation.Kind)
        error(`Unreachable.`)
    end
end

local function typeAnnotationToType(position: caw.Position, annotation: caw.TypeAnnotation): Type
    local ty = typeAnnotationToType_(position, annotation)
    return awn.reduceTypeFunctions(ty)
end

local function infer(state: InferenceState, expr: caw.Expression, expected: Type?): Type?
    if expr.Type == "Constant" then
        if expr.Constant.Type == "boolean" or expr.Constant.Type == "string" then
            return singletonType(expr.Constant.Value)
        else
            return makeType{ Kind = "Primitive", Primitive = expr.Constant.Type }
        end

    elseif expr.Type == "Declaration" then
        local anno = if expr.Declaration.Annotation then typeAnnotationToType(expr.Position, expr.Declaration.Annotation) else nil
        local expect = anno or freeType()

        local ty = if expr.Declaration.Value then infer(state, expr.Declaration.Value, expect) else nilType

        if not ty then
            errorReport(`Trying to assign '{ expr.Declaration.Name }' to an expression returning no values.`, expr.Position)
        end

        -- TODO luau type error on `ty` when `anno or` is removed
        localTypeAssociations[expr.Declaration.Name] = {
            Expression = expr,
            Type = anno or ty or errorType
        }
        table.insert(typeAssociationsOrdered, expr.Declaration.Name)

        if anno and ty then
            local position = if expr.Declaration.Value then expr.Declaration.Value.Position else expr.Position
            constrainSubtype(state, position, ty, anno)
        end

        return ty

    elseif expr.Type == "Reference" then
        local name = expr.Reference
        local referred = typeAssociations[name] or localTypeAssociations[name]

        if referred then
            return referred.Type
        else
            return errorReport(`Invalid reference '{ name }'.`, expr.Position)
        end

    elseif expr.Type == "List" then
        local itemsTy = if expected and expected.Kind == "List" and expected.Items.Kind ~= "Generic" then expected.Items else freeType()

        for _, item in expr.List do
            local currentItemTy = infer(state, item, itemsTy) or errorReport(`Expression does not return a value.`, item.Position)
            constrainSubtype(state, item.Position, currentItemTy, itemsTy)
        end

        itemsTy = substituteAllIn(itemsTy, {}, {})
        return listType(itemsTy)

    elseif expr.Type == "ReadIndex" then
        local itemsTy = freeType()

        local listTy = infer(state, expr.List, listType(itemsTy)) or errorReport(`Tried to index an expression that returned no value.`, expr.List.Position)
        local indexTy = infer(state, expr.Index, numberType) or errorReport(`Index was an expression that returned no value.`, expr.Index.Position)

        constrainSubtype(state, expr.List.Position, listTy, listType(itemsTy))
        constrainSubtype(state, expr.Index.Position, indexTy, numberType)

        return itemsTy

    elseif expr.Type == "WriteIndex" then
        local itemsTy = expected or freeType()

        local listTy = infer(state, expr.List, listType(itemsTy)) or errorReport(`Tried to index an expression that returned no value.`, expr.List.Position)
        local indexTy = infer(state, expr.Index, numberType) or errorReport(`Index was an expression that returned no value.`, expr.Index.Position)

        constrainSubtype(state, expr.List.Position, listTy, listType(itemsTy))
        constrainSubtype(state, expr.Index.Position, indexTy, numberType)

        local valueTy = infer(state, expr.Value, itemsTy)

        if not valueTy then
            return errorReport(`Tried to assign list index to an expression that returns no value.`, expr.Value.Position)
        end

        constrainSubtype(state, expr.Value.Position, valueTy, itemsTy)
        return valueTy

    elseif expr.Type == "UnaryOperation" then
        if expr.Operator == "-" then
            local operand = infer(state, expr.Operand, numberType)

            if operand then
                constrainSubtype(state, expr.Operand.Position, operand, numberType)
            else
                errorReport(`Attempted to use '-' on expression that returns no value.`, expr.Operand.Position)
            end

            return numberType

        elseif expr.Operator == "#" then
            local operand = infer(state, expr.Operand, unionType({ stringType, topListType }))

            if operand then
                constrainSubtype(state, expr.Operand.Position, operand, unionType({ stringType, topListType }))
            else
                errorReport(`Attempted to use '#' on expression that returns no value.`, expr.Operand.Position)
            end

            return numberType
        else
            unreachable(expr.Operator)
            error(`Unreachable.`)
        end

    elseif expr.Type == "BinaryOperation" then
        if expr.Operator == "=" then
            local variable = expr.Left
            local value = expr.Right

            assert(variable.Type == "Reference")
            local ref = typeAssociations[variable.Reference] or localTypeAssociations[variable.Reference]

            if not ref then
                return errorReport(`Undefined variable '{ variable.Reference }'.`, variable.Position)
            end

            if not ref.Expression then
                return errorReport(`Cannot assign to builtins.`, variable.Position)
            end

            assert(ref.Expression.Type == "Declaration" or ref.Expression.Type == "Function", ref.Expression.Type)

            local annoTy = if ref.Expression.Type == "Declaration" and ref.Expression.Declaration.Annotation then typeAnnotationToType(ref.Expression.Position, ref.Expression.Declaration.Annotation) else nil
            local valueTy = infer(state, value, annoTy or ref.Type)

            if not valueTy then
                return errorReport(`Tried to assign '{ variable.Reference }' to an expression that returns no value.`, expr.Position)
            end

            if ref.Expression.Type == "Function" then -- Function parameter.
                if ref.Type.Kind == "Free" and ref.Type ~= valueTy then
                    -- TODO luau, type error is reported on `ref.Type.UpperBound` instead of the `infer` call (returning optional `Type`).
                    -- local ty = makeIntersection(ref.Type.UpperBound, infer(state, value))
                    local ty = makeIntersection(ref.Type.UpperBound, valueTy)
                    ref.Type.UpperBound = ty

                    return ty
                else
                    return ref.Type
                end
            end

            assert(ref.Expression.Type == "Declaration")

            if annoTy then
                constrainSubtype(state, value.Position, valueTy, annoTy)
            else
                localTypeAssociations[variable.Reference] = {
                    Expression = ref.Expression,
                    Type = makeUnion(ref.Type, valueTy),
                }
            end

            return annoTy or valueTy
        elseif expr.Operator == "+" or expr.Operator == "-" or expr.Operator == "*"
            or expr.Operator == "/" or expr.Operator == "//"
        then
            local leftTy = infer(state, expr.Left, numberType)
            local rightTy = infer(state, expr.Right, numberType)

            if leftTy then
                constrainSubtype(state, expr.Left.Position, leftTy, numberType)
            else
                errorReport(`LHS is expression returning no value.`, expr.Left.Position)
            end

            if rightTy then
                constrainSubtype(state, expr.Right.Position, rightTy, numberType)
            else
                errorReport(`RHS is expression returning no value.`, expr.Right.Position)
            end

            return numberType

        elseif expr.Operator == ".." then
            local leftTy = infer(state, expr.Left, stringType)
            local rightTy = infer(state, expr.Right, stringType)

            if leftTy then
                constrainSubtype(state, expr.Left.Position, leftTy, stringType)
            else
                errorReport(`LHS is expression returning no value.`, expr.Left.Position)
            end

            if rightTy then
                constrainSubtype(state, expr.Right.Position, rightTy, stringType)
            else
                errorReport(`RHS is expression returning no value.`, expr.Right.Position)
            end

            return stringType

        elseif expr.Operator == "<" or expr.Operator == "<=" or expr.Operator == ">"
            or expr.Operator == ">="
        then
            local leftTy = infer(state, expr.Left, numberType)
            local rightTy = infer(state, expr.Right, numberType)

            if leftTy then
                constrainSubtype(state, expr.Left.Position, leftTy, numberType)
            else
                errorReport(`LHS is expression returning no value.`, expr.Left.Position)
            end

            if rightTy then
                constrainSubtype(state, expr.Right.Position, rightTy, numberType)
            else
                errorReport(`RHS is expression returning no value.`, expr.Right.Position)
            end

            return booleanType

        elseif expr.Operator == "==" or expr.Operator == "~=" then
            if not infer(state, expr.Left, unknownType) then
                errorReport(`LHS is expression returning no value.`, expr.Left.Position)
            end

            if not infer(state, expr.Right, unknownType) then
                errorReport(`RHS is expression returning no value.`, expr.Right.Position)
            end

            return booleanType
        elseif expr.Operator == "#" then
            return errorReport(`'#' is only valid as a unary operator.`, expr.Position)
        else
            unreachable(expr.Operator)
            error(`Cannot infer '{ expr.Operator }' operations.`)
        end
    elseif expr.Type == "Function" then
        local gens = table.create<<Type>>(#expr.Function.Parameters)

        for _, gen in expr.Function.Generics do
            local genTy = typeAnnotationToType(expr.Position, gen)
            typeEnv[gen.Name] = genTy
            table.insert(gens, genTy)
        end

        local params = table.create<<Type>>(#expr.Function.Parameters)

        for i, param in expr.Function.Parameters do
            local ty = if param.Annotation then typeAnnotationToType(expr.Position, param.Annotation)
                        else if expected and expected.Kind == "Function" then expected.Parameters[i] or freeType()
                        else freeType()

            params[i] = ty

            localTypeAssociations[param.Name] = {
                Expression = expr,
                Type = ty,
            }
        end

        if expr.Function.Name then
            localTypeAssociations[expr.Function.Name] = {
                Type = functionType({}, params, neverType, freeType()),
                Expression = expr,
            }

            table.insert(typeAssociationsOrdered, expr.Function.Name)
        end

        local prevVarTy = state.Variadic
        local prevRetTy = state.ReturnType

        if expr.Function.ReturnAnnotation then
            if expr.Function.ReturnAnnotation.Kind == "Unit" then
                state.ReturnType = false
            else
                state.ReturnType = typeAnnotationToType(expr.Position, expr.Function.ReturnAnnotation)
            end
        elseif expected and expected.Kind == "Function" then
            if expected.Returns == nil then
                state.ReturnType = false
            else
                state.ReturnType = expected.Returns
            end
        else
            state.ReturnType = true
        end

        if expr.Function.Variadic.Present then
            state.Variadic = freeType()
        else
            state.Variadic = nil
        end

        for _, expr in expr.Function.Body do
            infer(state, expr)
        end

        local retTy = state.ReturnType
        local varTy = state.Variadic
        state.ReturnType = prevRetTy
        state.Variadic = prevVarTy

        local generalizerOptions: GatherFreeTypeSubstitutionsOptions = {
            expression = expr,
            alwaysConcretize = false,
            polarity = "Unknown",
        }

        local generalizer: GatherFreeTypeSubstitutionsState = {
            options = generalizerOptions,
            substitutions = {},
            generics = {},

            polarities = {},
            polarity = "Unknown",
            inside = {},
        }

        log(`{ expr.Position.Line }:{ expr.Position.Column }: Eliminating free types: { typeToString(functionType(gens, params, varTy or neverType, if typeof(retTy) == "table" then retTy else nil)) }`)

        -- Inputs are negative.
        generalizer.polarity = "Negative"

        for i, param in expr.Function.Parameters do
            localTypeAssociations[param.Name] = nil

            local paramTy = params[i]

            if paramTy.Kind == "Free" then
                gatherFreeTypeSubstitutions_(generalizer, paramTy, `parameter '{ param.Name }'`)
            end
        end

        if varTy then
            gatherFreeTypeSubstitutions_(generalizer, varTy, "...")
        end

        -- Outputs are positive.
        generalizer.polarity = "Positive"

        if typeof(retTy) == "table" then
            gatherFreeTypeSubstitutions_(generalizer, retTy, "return type")
        end

        assert(next(generalizer.inside) == nil)

        if logInference then
            log("Free type substitutions:")
            for fty, ty in generalizer.substitutions do
                log(`* { typeToString(fty) } => { typeToString(ty) }{ if table.find(generalizer.generics, ty) then " (introduced generic)" else "" }`)
            end
            log("")
        end

        local substitutor: SubstitutionState = {
            substitutions = generalizer.substitutions,
            traversed = {},
            inside = {},
        }

        for i, param in params do
            params[i] = substituteAllIn_(param, substitutor)
        end

        if varTy then
            varTy = substituteAllIn_(varTy, substitutor)
        else
            varTy = neverType
        end

        if typeof(retTy) == "table" then
            retTy = substituteAllIn_(retTy, substitutor)
        end

        table.move(generalizer.generics, 1, #generalizer.generics, #gens + 1, gens)

        -- Trim unused generics, e.g. `let x = function(f, y) return f(y) end`.
        local gensCheck = table.clone(gens)
        table.clear(gens)

        for _, gen in gensCheck do
            assert(gen.Kind == "Generic")
            if gen.Name or substitutor.traversed[gen] then
                table.insert(gens, gen)
            end
        end

        local fty = functionType(gens, params, varTy, if typeof(retTy) == "table" then retTy else nil)

        if expr.Function.Name then
            localTypeAssociations[expr.Function.Name] = {
                Type = fty,
                Expression = expr,
            }
        end

        log("")
        return fty

    elseif expr.Type == "Return" then
        local retTy = state.ReturnType

        if retTy == true then
            local inferred = expr.Return and infer(state, expr.Return, freeType())

            if inferred then
                state.ReturnType = freeType(
                    unknownType,
                    inferred
                )
            else
                state.ReturnType = nil
            end

            assert(state.ReturnType ~= true)
            assert(state.ReturnType ~= false)
            return state.ReturnType

        elseif retTy ~= nil then
            if expr.Return then
                if retTy == false then
                    return errorReport(`Function is annotated as returning no value, but returning a value here.`, expr.Position)
                else
                    local thisRet = infer(state, expr.Return, if retTy.Kind == "Free" then freeType() else retTy)

                    if thisRet then
                        constrainSubtype(state, expr.Position, thisRet, retTy)
                        return retTy
                    end
                end
            else
                if retTy ~= false then
                    return errorReport(`Expected to return '{ typeToString(retTy) }', but not returning anything here.`, expr.Position)
                end
            end

            return nil
        else
            return errorReport(`Cannot 'return' outside of functions.`, expr.Position)
        end
    elseif expr.Type == "Call" then
        local fn = typeAssociations[expr.Call.Identifier] or localTypeAssociations[expr.Call.Identifier]

        if not fn then
            return errorReport(`Unknown function '{ expr.Call.Identifier }'.`, expr.Position)
        end

        local fnTy = fn.Type
        local arguments = table.create<<Type>>(#expr.Call.Arguments)

        for i, a in expr.Call.Arguments do
            local expect = (fnTy.Kind == "Function" and fnTy.Parameters[i]) or freeType()
            arguments[i] = infer(state, a, expect)
        end

        local callsiteTy = functionType({}, arguments, neverType, expected)

        log(`{ expr.Position.Line }:{ expr.Position.Column }: Instantiating '{ typeToString(fnTy) }' with '{ typeToString(callsiteTy) }'`)

        local erroneous, ftyToGeneric
        fnTy, erroneous, ftyToGeneric = instantiateGenericsAtCallsite(fnTy, callsiteTy)

        if #erroneous > 0 then
            for _, free in erroneous do
                local gen = ftyToGeneric[free]
                assert(free.Kind == "Free")

                local target = if gen then `'{ awn.typeToString(gen) }'` else "Argument"
                errorReport(`{ target } was expected to be '{ awn.typeToString(free.UpperBound) }' when returning, but was called in a way that it would be '{ awn.typeToString(free.LowerBound) }'.`, expr.Position)
            end

            return errorType
        end

        local normFn = if fnTy.Kind == "Free" then normalize(fnTy.UpperBound) else normalize(fnTy)

        if not normFn.functions or not isSubtypeOf(normFn, normalize(topFunctionType)).holds then
            return errorReport(`'{ normalizationToString(normFn) }' is not callable.`, expr.Position)
        end

        assert(normFn.functions)

        if not normFn.functions.components then
            return errorReport(`The top 'function' type is not safe to call.`, expr.Position)
        end

        local failed = {}

        for _, component in normFn.functions.components do
            if #component.parameters ~= #arguments and isNever(component.variadic) then
                table.insert(failed, `'{ normalizedFunctionComponentToString(component) }' expects { #component.parameters } argument(s).`)
                continue
            end

            local boundsChanges = {}
            local allOk = true

            for i, param in component.parameters do
                local result = isSubtypeOf(normalize(arguments[i]), param)

                if result.holds then
                    table.insert(boundsChanges, result.requiredBoundsChanges)
                else
                    table.insert(failed, `'{ normalizedFunctionComponentToString(component) }' expects argument { i } to be '{ normalizationToString(param) }'.`)
                    allOk = false
                end
            end

            for i = #component.parameters + 1, #arguments do
                local result = isSubtypeOf(normalize(arguments[i]), component.variadic)

                if result.holds then
                    table.insert(boundsChanges, result.requiredBoundsChanges)
                else
                    local signature = normalizedFunctionComponentToString(component)
                    local wanted = normalizationToString(component.variadic)
                    local got = typeToString(arguments[i])
                    table.insert(failed, `'{ signature }' expects argument { i } to be '{ wanted }', but got '{ got }'.`)
                    allOk = false
                end
            end

            if allOk then
                for _, changes in boundsChanges do
                    applyBoundsChanges(changes)
                end

                return if component.returns then normalizationToType(component.returns) else nil
            end
        end

        if #normFn.functions.components == 1 then
            errorReport(failed[1], expr.Position)

            local returns = normFn.functions.components[1].returns
            return if returns then normalizationToType(returns) else nil
        end

        local function overloadResolutionFailed(normError)
            if #failed > 0 then
                return errorReport(`Failed to resolve overload.\n* { table.concat(failed, "\n* ") }`, expr.Position)
            else
                return errorReport(normError, expr.Position)
            end
        end

        if #arguments ~= 1 then
            return overloadResolutionFailed("Internal error: Overload resolution failed but no errors were propagated.")
        end

        local normArgs = table.create<<NormalizedType>>(#arguments)

        for i, a in arguments do
            normArgs[i] = normalize(a)
        end

        local singles = decomposeToSingletons(normArgs[1])

        if singles then
            local ret = normalizedNever()
            local anySucceeded = false

            for _, single in singles do
                local thisRet = intersectApplicableReturns(normFn.functions.components, single)

                if thisRet then
                    ret = union(ret, thisRet)
                    anySucceeded = true
                end
            end

            if not anySucceeded then
                local argStrings = table.create<<string>>(#arguments)

                for i, a in arguments do
                    argStrings[i] = typeToString(a)
                end

                return overloadResolutionFailed(`No overload of '{ typeToString(fnTy) }' accepts arguments '({ table.concat(argStrings, ", ") })'.`, expr.Position)
            end

            return normalizationToType(ret)
        else
            return overloadResolutionFailed(`Cannot resolve overload for non-composite argument '{ normalizationToString(normArgs[1]) }'.`, expr.Position)
        end

    elseif expr.Type == "IfCondition" then -- TODO luau cast?
        infer(state, expr.Condition)

        local result = nil

        for _, v in expr.IfBody do
            result = infer(state, v)
        end

        if expr.ElseBody then
            local last

            for _, v in expr.ElseBody do
                last = infer(state, v)
            end

            if last and result then
                result = makeUnion(result, last)
            end
        end

        if result and expected then
            constrainSubtype(state, expr.Position, result, expected)
        end

        return result

    elseif expr.Type == "VariadicArguments" then
        if state.Variadic then
            return state.Variadic
        else
            return errorReport(`Function does not have a variadic.`, expr.Position)
        end
    elseif expr.Type == "VariadicSelection" then
        if state.Variadic then
            local selector = infer(state, expr.Selection)

            if selector then
                constrainSubtype(state, expr.Selection.Position, selector, numberType)
            else
                errorReport(`Tried to select with expression that returns no value.`, expr.Selection.Position)
            end

            return state.Variadic
        else
            return errorReport(`Function does not have a variadic.`, expr.Position)
        end

    elseif expr.Type == "VariadicLength" then
        if not state.Variadic then
            errorReport(`Function does not have a variadic.`, expr.Position)
        end

        return numberType

    elseif expr.Type == "TypeAliasDeclaration" then
        if typeEnv[expr.Name] or localTypeEnv[expr.Name] then
            return errorReport(`Cannot re-define type '{ expr.Name }'.`, expr.Position)
        end

        local gens = nil

        if #expr.Generics > 0 then
            gens = table.create<<Type>>(#expr.Generics)

            for i, gen in expr.Generics do
                assert(gen.Kind == "Generic")

                local genTy = typeAnnotationToType(expr.Position, gen)
                gens[i] = genTy
                localTypeEnv[gen.Name] = genTy
            end
        end

        local ty = typeAnnotationToType(expr.Position, expr.Value)
        typeEnvGenericParameters[ty] = gens
        ty.AliasName = expr.Name

        if gens then
            for _, genTy in gens do
                assert(genTy.Kind == "Generic")
                localTypeEnv[assert(genTy.Name)] = nil
            end
        end

        localTypeEnv[expr.Name] = ty
        table.insert(typeEnvOrdered, expr.Name)

        return errorType
    elseif expr.Type == "InvalidSyntax" then
        return errorType
    else
        unreachable(expr.Type)
        error(`Unreachable.`)
    end
end

local function reportMismatch(a: Type, na: NormalizedType, b: Type, nb: NormalizedType, position: caw.Position, result: SubtypingResult)
    local err = `Type error: `

    local as = typeToString(a)
    local nas = normalizationToString(na)

    err ..= `'{ as }' `

    if nas ~= as then
        err ..= `(aka '{ nas }') `
    end

    err ..= "is not a subtype of "

    --[[
    if result.Variance == "Covariant" then
        err ..= "a subtype of "
    elseif result.Variance == "Contravariant" then
        err ..= "a supertype of "
    else
        err ..= "exactly "
    end
    ]]--

    local bs = typeToString(b)
    local nbs = normalizationToString(nb)

    err ..= `'{ bs }'`

    if nbs ~= bs then
        err ..= ` (aka '{ nbs }')`
    end

    err ..= `. { result.failedPath }`

    errorReport(err, position)
end

type Ok = { read State: "Ok", read Value: Type }
type Stuck = { read State: "Stuck" }
type Fail = { read State: "Failed", read Error: string }
type ReductionResult = Ok | Stuck | Fail

local function ok(value: Type): Ok
    return {
        State = "Ok",
        Value = value
    }
end

local function stuck(): Stuck
    return { State = "Stuck" }
end

local function fail(error: string): Fail
    return {
        State = "Failed",
        Error = error
    }
end

type TypeFunction = {
    read canReduceGenerics: boolean,
    read tryReduce: ({ read Type }) -> ReductionResult,
}

-- local typeFunctionsStuckOnTypeFunctions: { [Type]: { Type } } = {}

local function stick(typeFunction: TypeFunction, me: Type, ty: Type): Stuck | false
    if (ty.Kind == "Generic" and not typeFunction.canReduceGenerics) or ty.Kind == "Free" or ty.Kind == "PendingExpansion" then
        return stuck()
    --[[
    elseif ty.Kind == "PendingExpansion" then
        if typeFunctionsStuckOnTypeFunctions[ty] then
            table.insert(typeFunctionsStuckOnTypeFunctions[ty], me)
        else
            typeFunctionsStuckOnTypeFunctions[ty] = { me }
        end

        return stuck()
    ]]--
    else
        return false
    end
end

local function issubtypeof_TypeFunction(arguments: { read Type }): ReductionResult
    if #arguments ~= 2 then
        return fail(`Expected exactly 2 type arguments, got { #arguments } instead.`)
    end

    local a = arguments[1]
    local b = arguments[2]

    local na = normalize(a)
    local nb = normalize(b)

    return ok(singletonType(isSubtypeOf(na, nb).holds))
end

local function items_TypeFunction(arguments: { read Type }): ReductionResult
    if #arguments ~= 1 then
        return fail(`Expected exactly 1 type argument, got { #arguments } instead.`)
    end

    local norm = normalize(arguments[1])

    if not isSubtypeOf(norm, normalize(topListType)).holds then
        return fail(`Expected list type, got '{ typeToString(arguments[1]) }'.`)
    end

    if norm.lists and norm.lists.items then
        return ok(normalizationToType(norm.lists.items))
    else
        return ok(neverType)
    end
end

local function simplify_TypeFunction(arguments: { read Type }): ReductionResult
    if #arguments ~= 1 then
        return fail(`Expected exactly 1 type argument, got { #arguments } instead.`)
    end

    return ok(awn.simplify(arguments[1]))
end

local typeFunctions: { [string]: TypeFunction? } = {
    issubtypeof = {
        canReduceGenerics = false,
        tryReduce = issubtypeof_TypeFunction,
    },
    items = {
        canReduceGenerics = false,
        tryReduce = items_TypeFunction,
    },
    simplify = {
        canReduceGenerics = false,
        tryReduce = simplify_TypeFunction,
    },
}

local function reduceTypeFunctions(ty: Type): Type
    local inited: Type

    if ty.Kind == "error" or ty.Kind == "never" or ty.Kind == "unknown"
        or ty.Kind == "Primitive" or ty.Kind == "Singleton" or ty.Kind == "Generic"
        or ty.Kind == "Free"
    then
        inited = ty
    elseif ty.Kind == "PendingExpansion" then
        log(`Trying to reduce '{ typeToString(ty) }'`)

        local typeFunction = typeFunctions[ty.Name]
        local aliasing = typeEnv[ty.Name] or localTypeEnv[ty.Name]

        if typeFunction then
            local arguments = table.create<<Type>>(#ty.Arguments)

            for i, argument in ty.Arguments do
                argument = reduceTypeFunctions(argument)
                arguments[i] = argument

                if stick(typeFunction, ty, argument) then
                    log(`Stuck type function: '{ typeToString(ty) }' (on '{ typeToString(argument) }')`)
                    return ty
                end
            end

            local result = typeFunction.tryReduce(arguments)

            if result.State == "Ok" then
                log(`Reduction succeeded: { typeToString(ty) } => { typeToString(result.Value) }`)
                inited = result.Value
            elseif result.State == "Stuck" then
                log(`Type function stuck on reduction: '{ typeToString(ty) }'`)
                inited = ty
            elseif result.State == "Failed" then
                inited = errorReport(result.Error, { Line = 1, Column = 1, Offset = 1 })
            else
                unreachable(result.State)
            end
        elseif aliasing then
            local generics = typeEnvGenericParameters[aliasing]

            if generics then
                if #generics == #ty.Arguments then
                    local substitutions = {}

                    for i, gen in generics do
                        substitutions[gen] = ty.Arguments[i]
                    end

                    inited = substituteAllIn(aliasing, substitutions, {})
                    inited = reduceTypeFunctions(inited)
                else
                    inited = errorReport(`'{ ty.Name }' expects { #generics } type argument(s), but { #ty.Arguments } were given.`, { Line = 1, Column = 1, Offset = 1 })
                end
            else
                inited = errorReport(`'{ ty.Name }' does not accept type arguments.`, { Line = 1, Column = 1, Offset = 1 })
            end
        else
            inited = errorReport(`Invalid type function '{ ty.Name }'.`, { Line = 1, Column = 1, Offset = 1 })
        end
    elseif ty.Kind == "Negation" then
        inited = negationType(reduceTypeFunctions(ty.Negated))

    elseif ty.Kind == "Union" then
        local components = table.create<<Type>>(#ty.Components)

        for i, c in ty.Components do
            components[i] = reduceTypeFunctions(c)
        end

        inited = unionType(components)

    elseif ty.Kind == "Intersection" then
        local components = table.create<<Type>>(#ty.Components)

        for i, c in ty.Components do
            components[i] = reduceTypeFunctions(c)
        end

        inited = intersectionType(components)

    elseif ty.Kind == "List" then
        inited = listType(reduceTypeFunctions(ty.Items))
    elseif ty.Kind == "Function" then
        local params = table.create<<Type>>(#ty.Parameters)

        for i, param in ty.Parameters do
            params[i] = reduceTypeFunctions(param)
        end

        inited = functionType(
            ty.Generics,
            params,
            reduceTypeFunctions(ty.Variadic),
            if ty.Returns then reduceTypeFunctions(ty.Returns) else nil
        )
    else
        unreachable(ty.Kind)
        error(`Unreachable.`)
    end

    inited.AliasName = ty.AliasName
    return inited
end

function awn.check(inferred: Type, annotation: Type, position: caw.Position, printNote: boolean?)
    if annotation.Kind == "Error" then
        return
    end

    local normalizedInference = normalize(inferred)
    local normalizedAnnotation = normalize(annotation)

    local subtypeResult = isSubtypeOf(normalizedInference, normalizedAnnotation)

    if not subtypeResult.holds and not subtypeResult.errorSurpressed then
        reportMismatch(inferred, normalizedInference, annotation, normalizedAnnotation, position, subtypeResult)
    elseif printNote then
        table.insert(typeErrors, `'{ typeToString(inferred) }' is a subtype of '{ typeToString(annotation) }'.`)
    end
end

local function dumpResults()
    print("")

    -- TODO annotation?
    for _, err: string in typeErrors do
        print(err)
    end

    print("")

    for _, k in typeAssociationsOrdered do
        local t = localTypeAssociations[k]
        if t then
            print(`{ k }: { t.Type.AliasName or typeToString(reduceTypeFunctions(t.Type)) }`)
        end
    end

    print("")

    for _, k in typeEnvOrdered do
        local a = assert(localTypeEnv[k])
        local gens = typeEnvGenericParameters[a]
        local gensString = ""

        if gens then
            local gensStr = table.create<<string>>(#gens)

            for i, gen in gens do
                gensStr[i] = typeToString(gen)
            end

            gensString = `<{ table.concat(gensStr, ", ") }>`
        end

        print(`type { k }{ gensString } = { typeToString(simplify(reduceTypeFunctions(a)), { Alias = k }) }`)
    end
end

export type SolverResult = {
    read typeErrors: { read string? },
    read localTypeEnv: { read [string]: Type? },
    read localTypeAssociations: { read [string]: { read Expression: caw.Expression, read Type: Type }? }
}

function awn.run(expressions: { read caw.Expression }, options: { read LogInference: boolean, read DumpResults: boolean? }): SolverResult
    localTypeEnv = {}
    table.clear(typeEnvOrdered)
    localTypeAssociations = {}
    table.clear(typeAssociationsOrdered)
    typeErrors = {}

    logInference = options.LogInference

    local state: InferenceState = {
        ReturnType = nil,
    }

    for _, expr in expressions do
        infer(state, expr)
    end

    if options.DumpResults then
        dumpResults()
    end

    return {
        typeErrors = typeErrors,
        localTypeEnv = localTypeEnv,
        localTypeAssociations = localTypeAssociations,
    }
end

awn.normalize = normalize
awn.isSubtypeOf = isSubtypeOf
awn.isSupertypeOf = isSupertypeOf
awn.isExactly = isExactly

awn.intersect = intersect
awn.negate = negate
awn.union = union

awn.normalizationToType = normalizationToType

awn.typeToString = typeToString
awn.simplify = simplify

awn.instantiateGenericsAtCallsite = instantiateGenericsAtCallsite
awn.reduceTypeFunctions = reduceTypeFunctions

awn.makeType = makeType

awn.errorType = errorType
awn.neverType = neverType
awn.unknownType = unknownType
awn.nilType = nilType
awn.booleanType = booleanType
awn.numberType = numberType
awn.stringType = stringType
awn.topListType = topListType
awn.topFunctionType = topFunctionType

awn.freeType = freeType
awn.genericType = genericType
awn.pendingExpansionType = pendingExpansionType
awn.singletonType = singletonType
awn.listType = listType
awn.functionType = functionType
awn.negationType = negationType
awn.unionType = unionType
awn.intersectionType = intersectionType

return table.freeze(awn)
