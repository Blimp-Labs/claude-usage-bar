import XCTest
@testable import ClaudeUsageBar

final class UsageModelTests: XCTestCase {
    func testResetDateParsesTimestampWithoutTimezoneAsUTC() throws {
        let bucket = UsageBucket(
            utilization: 25.0,
            resetsAt: "2026-03-05T18:00:00"
        )

        XCTAssertEqual(bucket.resetsAtDate, date("2026-03-05T18:00:00Z"))
    }

    func testReconcileKeepsPreviousResetWhenServerTemporarilyDropsIt() throws {
        let previousReset = date("2026-03-05T18:00:00Z")
        let previous = usageResponse(
            fiveHour: UsageBucket(utilization: 88.0, resetsAt: iso(previousReset))
        )
        let current = usageResponse(
            fiveHour: UsageBucket(utilization: 89.0, resetsAt: nil)
        )

        let reconciled = current.reconciled(
            with: previous,
            now: date("2026-03-05T17:30:00Z")
        )

        XCTAssertEqual(reconciled.fiveHour?.resetsAtDate, previousReset)
    }

    func testReconcileAdvancesResetAfterRolloverWhenServerDropsIt() throws {
        let previousReset = date("2026-03-05T18:00:00Z")
        let previous = usageResponse(
            fiveHour: UsageBucket(utilization: 100.0, resetsAt: iso(previousReset))
        )
        let current = usageResponse(
            fiveHour: UsageBucket(utilization: 2.0, resetsAt: "not-a-date")
        )

        let reconciled = current.reconciled(
            with: previous,
            now: date("2026-03-05T18:05:00Z")
        )

        XCTAssertEqual(reconciled.fiveHour?.resetsAtDate, date("2026-03-05T23:00:00Z"))
    }

    func testReconcilePreservesValidServerReset() throws {
        let previous = usageResponse(
            fiveHour: UsageBucket(utilization: 100.0, resetsAt: "2026-03-05T18:00:00Z")
        )
        let current = usageResponse(
            fiveHour: UsageBucket(utilization: 2.0, resetsAt: "2026-03-05T22:00:00Z")
        )

        let reconciled = current.reconciled(
            with: previous,
            now: date("2026-03-05T18:05:00Z")
        )

        XCTAssertEqual(reconciled.fiveHour?.resetsAtDate, date("2026-03-05T22:00:00Z"))
    }

    // MARK: - Per-model weekly windows (`limits`)

    func testPerModelWeeklyReadsModelScopedLimits() throws {
        let response = try decode("""
        {
          "five_hour": {"utilization": 20.0, "resets_at": "2026-03-05T18:00:00Z"},
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": "2026-03-10T00:00:00Z",
             "scope": {"model": {"display_name": "Fable 5"}}},
            {"kind": "weekly_scoped", "group": "subscription", "percent": 71.0,
             "resets_at": "2026-03-10T00:00:00Z",
             "scope": {"model": {"display_name": "Opus"}}}
          ]
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Fable 5", "Opus"])
        XCTAssertEqual(response.perModelWeekly.first?.bucket.utilization, 48.5)
        XCTAssertEqual(
            response.perModelWeekly.first?.bucket.resetsAtDate,
            date("2026-03-10T00:00:00Z")
        )
    }

    func testPerModelWeeklyIgnoresNonWeeklyAndNonModelScopes() throws {
        let response = try decode("""
        {
          "limits": [
            {"kind": "five_hour_scoped", "group": "subscription", "percent": 10.0,
             "resets_at": null, "scope": {"model": {"display_name": "Fable 5"}}},
            {"kind": "weekly_scoped", "group": "subscription", "percent": 12.0,
             "resets_at": null, "scope": {"surface": {"display_name": "Cowork"}}},
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": null, "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Fable 5"])
    }

    func testPerModelWeeklyFallsBackToFixedFieldsForUncoveredModels() throws {
        let response = try decode("""
        {
          "seven_day_opus": {"utilization": 71.0, "resets_at": "2026-03-10T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 15.0, "resets_at": "2026-03-10T00:00:00Z"},
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": "2026-03-10T00:00:00Z",
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Fable 5", "Opus", "Sonnet"])
    }

    /// Deliberate tradeoff: only an exact model-name match suppresses the fixed
    /// row. A differently-labelled entry might measure a different window, and
    /// showing a redundant row is far better than hiding a real one.
    func testDifferentlyNamedLimitDoesNotSuppressTheFixedRow() throws {
        let response = try decode("""
        {
          "seven_day_opus": {"utilization": 88.0, "resets_at": null},
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 71.0,
             "resets_at": null, "scope": {"model": {"display_name": "Claude Opus 5"}}}
          ]
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Claude Opus 5", "Opus"])
        XCTAssertEqual(response.perModelWeekly.map(\.bucket.utilization), [71.0, 88.0])
    }

    func testPerModelWeeklyIsEmptyWhenNothingIsReported() throws {
        XCTAssertTrue(try decode("{}").perModelWeekly.isEmpty)
    }

    func testLimitResetAcceptsEpochSeconds() throws {
        let response = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": 1772668800,
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        XCTAssertEqual(
            response.perModelWeekly.first?.bucket.resetsAtDate,
            Date(timeIntervalSince1970: 1_772_668_800)
        )
    }

    func testReconcileAdvancesModelScopedResetAfterRollover() throws {
        let previous = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 99.0,
             "resets_at": "2026-03-05T18:00:00Z",
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)
        let current = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 1.0,
             "resets_at": null,
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        let reconciled = current.reconciled(with: previous, now: date("2026-03-05T18:05:00Z"))

        XCTAssertEqual(
            reconciled.perModelWeekly.first?.bucket.resetsAtDate,
            date("2026-03-12T18:00:00Z")
        )
    }

    func testReconcileDoesNotBorrowResetFromADifferentModel() throws {
        let previous = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 99.0,
             "resets_at": "2026-03-05T18:00:00Z",
             "scope": {"model": {"display_name": "Opus"}}}
          ]
        }
        """)
        let current = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 1.0,
             "resets_at": null,
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        let reconciled = current.reconciled(with: previous, now: date("2026-03-05T18:05:00Z"))

        XCTAssertNil(reconciled.perModelWeekly.first?.bucket.resetsAtDate)
    }

    func testTwoWindowsForOneModelGetDistinctIdsAndLabels() throws {
        let response = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": null, "scope": {"model": {"display_name": "Fable 5"}}},
            {"kind": "weekly_scoped", "group": "subscription", "percent": 12.0,
             "resets_at": null,
             "scope": {"model": {"display_name": "Fable 5"},
                       "surface": {"display_name": "Cowork"}}}
          ]
        }
        """)

        let rows = response.perModelWeekly
        XCTAssertEqual(rows.map(\.displayName), ["Fable 5", "Fable 5 (Cowork)"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2, "ForEach ids must not collide")
    }

    func testFixedFieldRowsHaveStableIdsDistinctFromLimits() throws {
        let response = try decode("""
        {
          "seven_day_opus": {"utilization": 71.0, "resets_at": null},
          "seven_day_sonnet": {"utilization": 15.0, "resets_at": null}
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.id), ["seven_day_opus", "seven_day_sonnet"])
    }

    func testPerModelWeeklySkipsEmptyDisplayNames() throws {
        let response = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": null, "scope": {"model": {"display_name": ""}}}
          ]
        }
        """)

        XCTAssertTrue(response.perModelWeekly.isEmpty)
    }

    func testFixedFieldWithoutUtilizationIsNotRendered() throws {
        let response = try decode("""
        {"seven_day_opus": {"utilization": null, "resets_at": "2026-03-10T00:00:00Z"}}
        """)

        XCTAssertTrue(response.perModelWeekly.isEmpty)
    }

    func testReconcileCarriesResetWhenTheServerRelabelsTheGroup() throws {
        let previous = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 99.0,
             "resets_at": "2026-03-05T18:00:00Z",
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)
        let current = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "overage_included", "percent": 1.0,
             "resets_at": null,
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        let reconciled = current.reconciled(with: previous, now: date("2026-03-05T18:05:00Z"))

        XCTAssertEqual(
            reconciled.perModelWeekly.first?.bucket.resetsAtDate,
            date("2026-03-12T18:00:00Z")
        )
    }

    func testReconcilePrefersTheExactScopeMatchOverTheGroupAgnosticOne() throws {
        let previous = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "other", "percent": 99.0,
             "resets_at": "2026-03-01T18:00:00Z",
             "scope": {"model": {"display_name": "Fable 5"}}},
            {"kind": "weekly_scoped", "group": "subscription", "percent": 99.0,
             "resets_at": "2026-03-05T18:00:00Z",
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)
        let current = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 1.0,
             "resets_at": null,
             "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        let reconciled = current.reconciled(with: previous, now: date("2026-03-05T18:05:00Z"))

        XCTAssertEqual(
            reconciled.perModelWeekly.first?.bucket.resetsAtDate,
            date("2026-03-12T18:00:00Z")
        )
    }

    func testReconcilePreservesExtraUsage() throws {
        let current = try decode("""
        {
          "five_hour": {"utilization": 10.0, "resets_at": "2026-03-05T18:00:00Z"},
          "extra_usage": {"is_enabled": true, "monthly_limit": 28000,
                          "used_credits": 5230, "utilization": 18.68}
        }
        """)

        let reconciled = current.reconciled(with: nil, now: date("2026-03-05T17:00:00Z"))

        XCTAssertEqual(reconciled.extraUsage?.isEnabled, true)
        XCTAssertEqual(reconciled.extraUsage?.usedCredits, 5230)
        XCTAssertEqual(reconciled.extraUsage?.monthlyLimit, 28000)
        XCTAssertEqual(reconciled.extraUsage?.utilization, 18.68)
    }

    // MARK: - Resilience to `limits` drift

    func testUnrecognisedLimitShapesDoNotBreakTheRestOfTheResponse() throws {
        let response = try decode("""
        {
          "five_hour": {"utilization": 25.0, "resets_at": "2026-03-05T18:00:00Z"},
          "seven_day": {"utilization": 45.0, "resets_at": "2026-03-10T00:00:00Z"},
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": "48.5",
             "resets_at": null, "scope": {"model": {"display_name": "Fable 5"}}},
            {"kind": "weekly_scoped", "group": "subscription", "percent": 12.0,
             "resets_at": null, "scope": {"model": "Opus"}},
            {"kind": "weekly_scoped", "group": "subscription", "percent": 33.0,
             "resets_at": null, "scope": {"model": {"display_name": "Sonnet"}}}
          ]
        }
        """)

        // The good entry survives; the two malformed ones are dropped.
        XCTAssertEqual(response.fiveHour?.utilization, 25.0)
        XCTAssertEqual(response.sevenDay?.utilization, 45.0)
        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Sonnet"])
    }

    func testLimitsOfAnUnexpectedTypeDegradeToNoRows() throws {
        let response = try decode("""
        {
          "five_hour": {"utilization": 25.0, "resets_at": null},
          "limits": {"unexpected": "object"}
        }
        """)

        XCTAssertEqual(response.fiveHour?.utilization, 25.0)
        XCTAssertTrue(response.perModelWeekly.isEmpty)
    }

    // MARK: - Dedup against the fixed fields

    func testNarrowerSurfaceScopedEntryDoesNotHideTheAccountWideRow() throws {
        let response = try decode("""
        {
          "seven_day_opus": {"utilization": 88.0, "resets_at": null},
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 5.0,
             "resets_at": null,
             "scope": {"model": {"display_name": "Opus"},
                       "surface": {"display_name": "Cowork"}}}
          ]
        }
        """)

        let rows = response.perModelWeekly
        XCTAssertEqual(rows.map(\.displayName), ["Opus (Cowork)", "Opus"])
        XCTAssertEqual(rows.last?.bucket.utilization, 88.0)
    }

    func testUnsurfacedEntryForTheSameModelStillSupersedesTheFixedRow() throws {
        let response = try decode("""
        {
          "seven_day_opus": {"utilization": 88.0, "resets_at": null},
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 71.0,
             "resets_at": null, "scope": {"model": {"display_name": "opus"}}}
          ]
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.bucket.utilization), [71.0])
    }

    func testTwoGroupsForOneModelGetDistinguishableLabels() throws {
        let response = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 100.0,
             "resets_at": null, "scope": {"model": {"display_name": "Opus"}}},
            {"kind": "weekly_scoped", "group": "overage", "percent": 3.0,
             "resets_at": null, "scope": {"model": {"display_name": "Opus"}}}
          ]
        }
        """)

        let rows = response.perModelWeekly
        XCTAssertEqual(rows.map(\.displayName), ["Opus — subscription", "Opus — overage"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
    }

    func testASingleGroupNeedsNoLabelSuffix() throws {
        let response = try decode("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "subscription", "percent": 48.5,
             "resets_at": null, "scope": {"model": {"display_name": "Fable 5"}}}
          ]
        }
        """)

        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Fable 5"])
    }

    // MARK: - Real captured payload

    /// Captured verbatim from `GET /api/oauth/usage` on a live account
    /// (2026-08-19). Pins the shape the server actually sends, including the
    /// fields the app ignores and the `kind`/`group` values it must tolerate.
    func testRealCapturedPayloadYieldsTheFableRow() throws {
        let response = try decode("""
        {
          "five_hour": {"utilization": 33.0, "resets_at": "2026-08-19T12:40:00.053135+00:00",
                        "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
          "seven_day": {"utilization": 33.0, "resets_at": "2026-08-22T03:00:00.053154+00:00",
                        "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
          "seven_day_oauth_apps": null, "seven_day_opus": null, "seven_day_sonnet": null,
          "seven_day_cowork": null, "seven_day_omelette": null, "tangelo": null,
          "iguana_necktie": null, "omelette_promotional": null,
          "nimbus_quill": {"utilization": 0.0, "resets_at": null},
          "cinder_cove": null, "amber_ladder": null,
          "extra_usage": {"is_enabled": false, "monthly_limit": 5000, "used_credits": 0.0,
                          "utilization": 0.0, "currency": "USD", "decimal_places": 2,
                          "disabled_reason": "out_of_credits", "user_disabled": false,
                          "spend_limit_reached": false, "credits_ever_enabled": true,
                          "daily": null, "weekly": null},
          "limits": [
            {"kind": "session", "group": "session", "percent": 33, "severity": "normal",
             "resets_at": "2026-08-19T12:40:00.053135+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_all", "group": "weekly", "percent": 33, "severity": "normal",
             "resets_at": "2026-08-22T03:00:00.053154+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 42, "severity": "normal",
             "resets_at": "2026-08-22T03:00:00.053375+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
             "is_active": true}
          ],
          "spend": {"percent": 0, "severity": "normal", "enabled": false},
          "member_dashboard_available": false
        }
        """)

        // The top-level bars are unaffected by everything new.
        XCTAssertEqual(response.fiveHour?.utilization, 33.0)
        XCTAssertEqual(response.sevenDay?.utilization, 33.0)

        // Exactly one per-model row: the session and weekly_all entries have no
        // model scope, and both fixed seven_day_* fields are null.
        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Fable"])
        XCTAssertEqual(response.perModelWeekly.first?.bucket.utilization, 42.0)
        XCTAssertNotNil(response.perModelWeekly.first?.bucket.resetsAtDate)
    }

    /// The real payload's group is "weekly", not "subscription" — a group
    /// allowlist would have hidden the only row the feature exists to show.
    func testRealPayloadGroupIsNotSubscription() throws {
        let response = try decode("""
        {"limits": [{"kind": "weekly_scoped", "group": "weekly", "percent": 42,
                     "resets_at": null,
                     "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}]}
        """)

        XCTAssertEqual(response.limits?.first?.group, "weekly")
        XCTAssertEqual(response.perModelWeekly.map(\.displayName), ["Fable"])
    }

    private func decode(_ json: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    private func usageResponse(fiveHour: UsageBucket? = nil) -> UsageResponse {
        UsageResponse(
            fiveHour: fiveHour,
            sevenDay: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            extraUsage: nil
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
