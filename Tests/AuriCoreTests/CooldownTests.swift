import XCTest
@testable import AuriCore

final class SpeciesCooldownTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testFirstCallAlwaysAllowed() {
        var cooldown = SpeciesCooldown()
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: now))
    }

    func testCooldownWindowRespectsJitterBounds() {
        var cooldown = SpeciesCooldown()
        cooldown.markNotified(speciesId: 1, cooldownSeconds: 100, now: now)

        // Jitter is drawn from 0...(cooldown * 0.1) == 0...10, so the next
        // allowed instant always falls in [now+100, now+110].
        XCTAssertFalse(cooldown.shouldAllow(speciesId: 1, now: now.addingTimeInterval(99)))
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: now.addingTimeInterval(111)))
    }

    func testJitterNeverExceedsUpperBound() {
        // Repeat many times to guard against the random jitter ever pushing
        // the next-allowed instant past now+110 (the documented upper bound).
        for _ in 0..<20 {
            var cooldown = SpeciesCooldown()
            cooldown.markNotified(speciesId: 1, cooldownSeconds: 100, now: now)
            XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: now.addingTimeInterval(110.001)))
        }
    }

    func testZeroCooldownAllowsImmediately() {
        var cooldown = SpeciesCooldown()
        cooldown.markNotified(speciesId: 1, cooldownSeconds: 0, now: now)
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: now))
    }

    func testNegativeCooldownIsClampedToZero() {
        var cooldown = SpeciesCooldown()
        cooldown.markNotified(speciesId: 1, cooldownSeconds: -50, now: now)
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: now))
    }

    func testCooldownIsIndependentPerSpecies() {
        var cooldown = SpeciesCooldown()
        cooldown.markNotified(speciesId: 1, cooldownSeconds: 100, now: now)

        XCTAssertFalse(cooldown.shouldAllow(speciesId: 1, now: now))
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 2, now: now))
    }

    func testResetClearsAllCooldowns() {
        var cooldown = SpeciesCooldown()
        cooldown.markNotified(speciesId: 1, cooldownSeconds: 100, now: now)
        XCTAssertFalse(cooldown.shouldAllow(speciesId: 1, now: now.addingTimeInterval(1)))

        cooldown.reset()
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: now.addingTimeInterval(1)))
    }
}

final class TimelineSpeciesCooldownTests: XCTestCase {
    func testFirstCallAlwaysAllowed() {
        var cooldown = TimelineSpeciesCooldown()
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: 0))
    }

    func testDeterministicCooldownWindow() {
        var cooldown = TimelineSpeciesCooldown()
        cooldown.markQualified(speciesId: 1, cooldownSeconds: 3600, now: 10)

        XCTAssertFalse(cooldown.shouldAllow(speciesId: 1, now: 3609))
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: 3610))
    }

    func testZeroCooldownAllowsImmediately() {
        var cooldown = TimelineSpeciesCooldown()
        cooldown.markQualified(speciesId: 1, cooldownSeconds: 0, now: 10)
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: 10))
    }

    func testNegativeCooldownIsClampedToZero() {
        var cooldown = TimelineSpeciesCooldown()
        cooldown.markQualified(speciesId: 1, cooldownSeconds: -50, now: 10)
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: 10))
    }

    func testCooldownIsIndependentPerSpecies() {
        var cooldown = TimelineSpeciesCooldown()
        cooldown.markQualified(speciesId: 1, cooldownSeconds: 3600, now: 10)

        XCTAssertFalse(cooldown.shouldAllow(speciesId: 1, now: 10))
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 2, now: 10))
    }

    func testResetClearsAllCooldowns() {
        var cooldown = TimelineSpeciesCooldown()
        cooldown.markQualified(speciesId: 1, cooldownSeconds: 3600, now: 10)
        XCTAssertFalse(cooldown.shouldAllow(speciesId: 1, now: 11))

        cooldown.reset()
        XCTAssertTrue(cooldown.shouldAllow(speciesId: 1, now: 11))
    }
}

final class NotificationRateLimiterTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testZeroMaxPerHourAlwaysAllowed() {
        var limiter = NotificationRateLimiter()
        for _ in 0..<10 {
            limiter.markNotified(now: now)
        }
        XCTAssertTrue(limiter.shouldAllow(maxPerHour: 0, now: now))
    }

    func testNegativeMaxPerHourAlwaysAllowed() {
        var limiter = NotificationRateLimiter()
        for _ in 0..<10 {
            limiter.markNotified(now: now)
        }
        XCTAssertTrue(limiter.shouldAllow(maxPerHour: -1, now: now))
    }

    func testDeniesOnceMaxReached() {
        var limiter = NotificationRateLimiter()
        XCTAssertTrue(limiter.shouldAllow(maxPerHour: 3, now: now))

        limiter.markNotified(now: now)
        XCTAssertTrue(limiter.shouldAllow(maxPerHour: 3, now: now))

        limiter.markNotified(now: now)
        XCTAssertTrue(limiter.shouldAllow(maxPerHour: 3, now: now))

        limiter.markNotified(now: now)
        XCTAssertFalse(limiter.shouldAllow(maxPerHour: 3, now: now))
    }

    func testSlidingWindowPrunesOldTimestamps() {
        var limiter = NotificationRateLimiter()
        limiter.markNotified(now: now)
        limiter.markNotified(now: now)
        limiter.markNotified(now: now)
        XCTAssertFalse(limiter.shouldAllow(maxPerHour: 3, now: now))

        // An hour and a second later, the three marks should have aged out.
        XCTAssertTrue(limiter.shouldAllow(maxPerHour: 3, now: now.addingTimeInterval(3601)))
    }
}
