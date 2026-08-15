import Foundation

enum Analytic {
    private static let minimumProbability: Float = 1e-7
    private static let maximumProbability: Float = 1 - 1e-7

    private struct CurveCache {
        let t, stability, decay, factor, base, retrievability: Float
    }

    private struct StepCache {
        let stateS, stateD, lastS, lastD, deltaT, rating, retrievability: Float
        let failureRaw, failureFloor: Float
        let failureUsedFloor: Bool
        let shortRaw, shortValue: Float
        let shortRawActive, useShort, useFailure, initSelected, padding: Bool
        let preClampS, meanPreClampD: Float
        let initRating: Int
    }

    private struct State { let stability, difficulty: Float }

    private struct Runtime {
        let weights: [Float]
        let curveDecay, curveFactor: Float
        let curveDFactorDDecay: Double
        let expW8: Float
        let expW8Double: Double
        let failureFloorDivisor: Float
        let easyD: Float
        let easyDDouble: Double
        let exp3W5Double: Double

        init(_ weights: [Float]) {
            self.weights = weights
            curveDecay = -weights[20]
            curveFactor = exp(log(Float(0.9)) / curveDecay) - 1
            let decay = Double(curveDecay)
            let c = log(0.9)
            curveDFactorDDecay = exp(c / decay) * (-c / (decay * decay))
            expW8 = exp(weights[8])
            expW8Double = exp(Double(weights[8]))
            failureFloorDivisor = exp(weights[17] * weights[18])
            easyD = initialDifficulty(weights, 4)
            easyDDouble = Double(easyD)
            exp3W5Double = exp(3 * Double(weights[5]))
        }
    }

    private static func clampGradient(_ value: Float, _ lower: Float, _ upper: Float) -> Double {
        value >= lower && value <= upper ? 1 : 0
    }

    private static func add(_ gradient: inout [Double], _ index: Int, _ value: Double) {
        gradient[index] += value
    }

    private static func binaryCrossEntropy(
        prediction raw: Float,
        label: Float,
        weight: Float
    ) -> (Double, Double) {
        guard weight != 0 else { return (0, 0) }
        let prediction = min(maximumProbability, max(minimumProbability, raw))
        let loss = -(label * log(prediction) + (1 - label) * log(1 - prediction)) * weight
        let rawGradient = -weight * (label / prediction - (1 - label) / (1 - prediction))
        let gradient = raw > minimumProbability && raw < maximumProbability
            ? Double(rawGradient) : 0
        return (Double(loss), gradient)
    }

    private static func curve(_ runtime: Runtime, _ t: Float, _ stability: Float) -> CurveCache {
        let t = max(0, t)
        let base = t / stability * runtime.curveFactor + 1
        return CurveCache(
            t: t,
            stability: stability,
            decay: runtime.curveDecay,
            factor: runtime.curveFactor,
            base: base,
            retrievability: pow(base, runtime.curveDecay)
        )
    }

    private static func backwardCurve(
        _ runtime: Runtime,
        _ cache: CurveCache,
        _ upstream: Double,
        _ gradient: inout [Double]
    ) -> Double {
        guard upstream != 0 else { return 0 }
        let r = Double(cache.retrievability)
        let base = Double(cache.base)
        let decay = Double(cache.decay)
        let t = Double(cache.t)
        let stability = Double(cache.stability)
        let factor = Double(cache.factor)
        let dBaseDStability = -t * factor / (stability * stability)
        let stabilityGradient = upstream * r * decay / base * dBaseDStability
        let dBaseDDecay = t / stability * runtime.curveDFactorDDecay
        let dRDDecay = r * (log(base) + decay / base * dBaseDDecay)
        add(&gradient, 20, -upstream * dRDDecay)
        return stabilityGradient
    }

    private static func initialDifficulty(_ weights: [Float], _ rating: Int) -> Float {
        let offset = Float(max(0, rating - 1))
        return weights[4] - exp(weights[5] * offset) + 1
    }

    private static func forwardStep(
        _ runtime: Runtime,
        _ state: State,
        _ deltaT: Float,
        _ rating: Float,
        _ nth: Int
    ) -> (State, StepCache) {
        let w = runtime.weights
        let lastS = min(36_500, max(0.001, state.stability))
        let lastD = min(10, max(1, state.difficulty))
        if rating == 0 {
            let cache = StepCache(
                stateS: state.stability, stateD: state.difficulty, lastS: lastS, lastD: lastD,
                deltaT: deltaT, rating: rating, retrievability: 0, failureRaw: 0,
                failureFloor: 0, failureUsedFloor: false, shortRaw: 0, shortValue: 0,
                shortRawActive: false, useShort: false, useFailure: false,
                initSelected: false, padding: true, preClampS: lastS,
                meanPreClampD: lastD, initRating: 1
            )
            return (State(stability: lastS, difficulty: lastD), cache)
        }
        let initSelected = nth == 0 && state.stability == 0
        let initRating = Int(min(4, max(1, rating)))
        if initSelected {
            let newS = w[initRating - 1]
            let rawD = initialDifficulty(w, initRating)
            let cache = StepCache(
                stateS: state.stability, stateD: state.difficulty, lastS: lastS, lastD: lastD,
                deltaT: deltaT, rating: rating, retrievability: 0, failureRaw: 0,
                failureFloor: 0, failureUsedFloor: false, shortRaw: 0, shortValue: 0,
                shortRawActive: false, useShort: false, useFailure: false,
                initSelected: true, padding: false, preClampS: newS,
                meanPreClampD: rawD, initRating: initRating
            )
            return (State(stability: min(36_500, max(0.001, newS)), difficulty: min(10, max(1, rawD))), cache)
        }

        let curveCache = curve(runtime, deltaT, lastS)
        let r = curveCache.retrievability
        let useShort = deltaT == 0
        let useFailure = rating == 1
        var failureRaw: Float = 0
        var failureFloor: Float = 0
        var failureUsedFloor = false
        var shortRaw: Float = 0
        var shortValue: Float = 0
        var shortRawActive = false
        let newS: Float
        if useShort {
            shortRaw = exp(w[17] * (rating - 3 + w[18])) * pow(lastS, -w[19])
            shortRawActive = !(rating >= 2 && shortRaw < 1)
            shortValue = rating >= 2 ? max(1, shortRaw) : shortRaw
            newS = lastS * shortValue
        } else if useFailure {
            failureRaw = w[11] * pow(lastD, -w[12]) * (pow(lastS + 1, w[13]) - 1)
                * exp((1 - r) * w[14])
            failureFloor = lastS / runtime.failureFloorDivisor
            failureUsedFloor = failureFloor < failureRaw
            newS = failureUsedFloor ? failureFloor : failureRaw
        } else {
            let hardPenalty: Float = rating == 2 ? w[15] : 1
            let easyBonus: Float = rating == 4 ? w[16] : 1
            let increment = runtime.expW8 * (11 - lastD) * pow(lastS, -w[9])
                * (exp((1 - r) * w[10]) - 1) * hardPenalty * easyBonus
            newS = lastS * (increment + 1)
        }
        let deltaD = -w[6] * (rating - 3)
        let nextD = lastD + (10 - lastD) * deltaD / 9
        let meanD = w[7] * (runtime.easyD - nextD) + nextD
        let output = State(stability: min(36_500, max(0.001, newS)), difficulty: min(10, max(1, meanD)))
        let cache = StepCache(
            stateS: state.stability, stateD: state.difficulty, lastS: lastS, lastD: lastD,
            deltaT: deltaT, rating: rating, retrievability: r, failureRaw: failureRaw,
            failureFloor: failureFloor, failureUsedFloor: failureUsedFloor, shortRaw: shortRaw,
            shortValue: shortValue, shortRawActive: shortRawActive, useShort: useShort,
            useFailure: useFailure, initSelected: false, padding: false, preClampS: newS,
            meanPreClampD: meanD, initRating: initRating
        )
        return (output, cache)
    }

    private static func backwardSuccess(
        _ runtime: Runtime, _ cache: StepCache, _ upstream: Double,
        _ gradient: inout [Double]
    ) -> (Double, Double, Double) {
        guard upstream != 0 else { return (0, 0, 0) }
        let w = runtime.weights
        let stability = Double(cache.lastS), difficulty = Double(cache.lastD)
        let retrievability = Double(cache.retrievability)
        let a = runtime.expW8Double, b = 11 - difficulty
        let c = pow(stability, -Double(w[9]))
        let e = exp((1 - retrievability) * Double(w[10])) - 1
        let expE = e + 1
        let hard = cache.rating == 2 ? Double(w[15]) : 1
        let easy = cache.rating == 4 ? Double(w[16]) : 1
        let increment = a * b * c * e * hard * easy
        let gIncrement = upstream * stability
        var gStability = upstream * (increment + 1)
        gStability += gIncrement * increment * (-Double(w[9]) / stability)
        let gDifficulty = -(gIncrement * a * c * e * hard * easy)
        let gR = gIncrement * a * b * c * hard * easy * (-Double(w[10]) * expE)
        add(&gradient, 8, gIncrement * increment)
        add(&gradient, 9, gIncrement * increment * -log(stability))
        add(&gradient, 10, gIncrement * a * b * c * hard * easy * ((1 - retrievability) * expE))
        if cache.rating == 2 { add(&gradient, 15, gIncrement * a * b * c * e * easy) }
        if cache.rating == 4 { add(&gradient, 16, gIncrement * a * b * c * e * hard) }
        return (gStability, gDifficulty, gR)
    }

    private static func backwardFailure(
        _ runtime: Runtime, _ cache: StepCache, _ upstream: Double,
        _ gradient: inout [Double]
    ) -> (Double, Double, Double) {
        guard upstream != 0 else { return (0, 0, 0) }
        let w = runtime.weights
        let stability = Double(cache.lastS), difficulty = Double(cache.lastD)
        let retrievability = Double(cache.retrievability)
        if cache.failureUsedFloor {
            let floor = Double(cache.failureFloor)
            add(&gradient, 17, upstream * floor * -Double(w[18]))
            add(&gradient, 18, upstream * floor * -Double(w[17]))
            return (upstream * floor / stability, 0, 0)
        }
        let raw = Double(cache.failureRaw)
        let base = stability + 1
        let p = pow(base, Double(w[13]))
        let dPower = pow(difficulty, -Double(w[12]))
        let eR = exp((1 - retrievability) * Double(w[14]))
        add(&gradient, 11, upstream * raw / Double(w[11]))
        add(&gradient, 12, upstream * raw * -log(difficulty))
        add(&gradient, 13, upstream * Double(w[11]) * dPower * eR * p * log(base))
        add(&gradient, 14, upstream * raw * (1 - retrievability))
        let gS = upstream * Double(w[11]) * dPower * eR * Double(w[13]) * p / base
        let gD = upstream * raw * (-Double(w[12]) / difficulty)
        let gR = upstream * raw * -Double(w[14])
        return (gS, gD, gR)
    }

    private static func backwardShort(
        _ runtime: Runtime, _ cache: StepCache, _ upstream: Double,
        _ gradient: inout [Double]
    ) -> Double {
        guard upstream != 0 else { return 0 }
        let w = runtime.weights
        let stability = Double(cache.lastS)
        var gS = upstream * Double(cache.shortValue)
        if cache.shortRawActive {
            let gRaw = upstream * stability
            let raw = Double(cache.shortRaw)
            let q = Double(cache.rating - 3 + w[18])
            add(&gradient, 17, gRaw * raw * q)
            add(&gradient, 18, gRaw * raw * Double(w[17]))
            add(&gradient, 19, gRaw * raw * -log(stability))
            gS += gRaw * raw * (-Double(w[19]) / stability)
        }
        return gS
    }

    private static func backwardDifficulty(
        _ runtime: Runtime, _ cache: StepCache, _ upstream: Double,
        _ gradient: inout [Double]
    ) -> Double {
        guard upstream != 0 else { return 0 }
        let w = runtime.weights
        let gMean = upstream * clampGradient(cache.meanPreClampD, 1, 10)
        guard gMean != 0 else { return 0 }
        let ratingMinus3 = Double(cache.rating - 3)
        let lastD = Double(cache.lastD)
        let deltaD = -Double(w[6]) * ratingMinus3
        let nextD = lastD + (10 - lastD) * deltaD / 9
        add(&gradient, 7, gMean * (runtime.easyDDouble - nextD))
        add(&gradient, 4, gMean * Double(w[7]))
        add(&gradient, 5, gMean * Double(w[7]) * -3 * runtime.exp3W5Double)
        let gNext = gMean * (1 - Double(w[7]))
        add(&gradient, 6, gNext * (10 - lastD) * -ratingMinus3 / 9)
        return gNext * (1 - deltaD / 9)
    }

    private static func backwardInitial(
        _ runtime: Runtime, _ rating: Int, _ gS: Double, _ gD: Double,
        _ gradient: inout [Double]
    ) {
        add(&gradient, rating - 1, gS)
        let rawD = initialDifficulty(runtime.weights, rating)
        let gRawD = gD * clampGradient(rawD, 1, 10)
        guard gRawD != 0 else { return }
        let offset = Double(rating - 1)
        add(&gradient, 4, gRawD)
        add(&gradient, 5, gRawD * -offset * exp(offset * Double(runtime.weights[5])))
    }

    private static func backwardStep(
        _ runtime: Runtime, _ cache: StepCache,
        _ outputS: Double, _ outputD: Double, _ extraR: Double,
        _ gradient: inout [Double]
    ) -> (Double, Double) {
        let preS = outputS * clampGradient(cache.preClampS, 0.001, 36_500)
        let preD = outputD
        var lastS = 0.0, lastD = 0.0, gR = extraR
        if cache.padding {
            lastS += preS
            lastD += preD
        } else if cache.initSelected {
            backwardInitial(runtime, cache.initRating, preS, preD, &gradient)
        } else {
            if cache.useShort {
                lastS += backwardShort(runtime, cache, preS, &gradient)
            } else if cache.useFailure {
                let result = backwardFailure(runtime, cache, preS, &gradient)
                lastS += result.0; lastD += result.1; gR += result.2
            } else {
                let result = backwardSuccess(runtime, cache, preS, &gradient)
                lastS += result.0; lastD += result.1; gR += result.2
            }
            lastD += backwardDifficulty(runtime, cache, preD, &gradient)
        }
        let t = max(0, cache.deltaT)
        let curveCache = CurveCache(
            t: t, stability: cache.lastS, decay: runtime.curveDecay,
            factor: runtime.curveFactor,
            base: t / cache.lastS * runtime.curveFactor + 1,
            retrievability: cache.retrievability
        )
        lastS += backwardCurve(runtime, curveCache, gR, &gradient)
        return (
            lastS * clampGradient(cache.stateS, 0.001, 36_500),
            lastD * clampGradient(cache.stateD, 1, 10)
        )
    }

    static func prefixLossAndGradient(
        weights: [Float],
        timeHistory: [Float],
        ratingHistory: [Float],
        sequenceLength: Int,
        batchSize: Int,
        sequenceLengths: [Int],
        deltaTimes: [Float],
        labels: [Float],
        exampleWeights: [Float],
        gradient: inout [Double]
    ) -> Double {
        let runtime = Runtime(weights)
        var total = 0.0
        for column in 0..<batchSize {
            var state = State(stability: 0, difficulty: 0)
            var caches: [StepCache] = []
            let columnLength = min(sequenceLengths[column], sequenceLength)
            for time in 0..<columnLength {
                let index = time * batchSize + column
                let result = forwardStep(runtime, state, timeHistory[index], ratingHistory[index], time)
                state = result.0
                caches.append(result.1)
            }
            let prediction = curve(runtime, deltaTimes[column], state.stability)
            let loss = binaryCrossEntropy(
                prediction: prediction.retrievability,
                label: labels[column],
                weight: exampleWeights[column]
            )
            total += loss.0
            var gS = backwardCurve(runtime, prediction, loss.1, &gradient)
            var gD = 0.0
            for cache in caches.reversed() {
                let previous = backwardStep(runtime, cache, gS, gD, 0, &gradient)
                gS = previous.0; gD = previous.1
            }
        }
        return total
    }

    static func cardLossAndGradient(
        weights: [Float],
        timeHistory: [Float],
        ratingHistory: [Float],
        sequenceLength: Int,
        batchSize: Int,
        sequenceLengths: [Int],
        labels: [Float],
        exampleWeights: [Float],
        gradient: inout [Double]
    ) -> Double {
        let runtime = Runtime(weights)
        var total = 0.0
        for column in 0..<batchSize {
            let length = min(sequenceLengths[column], sequenceLength)
            var state = State(stability: 0, difficulty: 0)
            var caches: [StepCache] = []
            var reviewGradients = [Double](repeating: 0, count: length)
            var finalS = 0.0
            for time in 0..<length {
                let index = time * batchSize + column
                if time + 1 == length {
                    if time != 0 && exampleWeights[index] != 0 {
                        let prediction = curve(runtime, timeHistory[index], min(36_500, max(0.001, state.stability)))
                        let loss = binaryCrossEntropy(
                            prediction: prediction.retrievability,
                            label: labels[index], weight: exampleWeights[index]
                        )
                        total += loss.0
                        finalS = backwardCurve(runtime, prediction, loss.1, &gradient)
                            * clampGradient(state.stability, 0.001, 36_500)
                    }
                    var gS = finalS, gD = 0.0
                    for cacheIndex in caches.indices.reversed() {
                        let previous = backwardStep(
                            runtime, caches[cacheIndex], gS, gD,
                            reviewGradients[cacheIndex], &gradient
                        )
                        gS = previous.0; gD = previous.1
                    }
                    break
                }
                let result = forwardStep(runtime, state, timeHistory[index], ratingHistory[index], time)
                let scored = time == 0 ? (0.0, 0.0) : binaryCrossEntropy(
                    prediction: result.1.retrievability,
                    label: labels[index], weight: exampleWeights[index]
                )
                total += scored.0
                reviewGradients[time] = scored.1
                caches.append(result.1)
                state = result.0
            }
        }
        return total
    }
}
