import Foundation

/// Internal Codable DTOs that mirror the wire shape of `https://status.claude.com/api/v2/summary.json`
/// (Statuspage.io v2). Confirmed live during the DV-1.1 spike — see `.context/spike-status-claude.md`.
///
/// These types are intentionally `internal` (not `public`): callers consume the domain types
/// (`StatusPageSummary`, `StatusComponent`, `StatusIncident`) instead, which keeps the wire
/// format swappable behind the `HTTPClient` boundary.

struct StatuspageSummaryDTO: Decodable {
    let components: [StatuspageComponentDTO]
    let incidents: [StatuspageIncidentDTO]
}

struct StatuspageComponentDTO: Decodable {
    let id: String
    let name: String
    let status: String
    let groupId: String?
    let updatedAt: Date?
}

struct StatuspageIncidentDTO: Decodable {
    let id: String
    let name: String
    let status: String
    let impact: String
    let shortlink: URL?
    let updatedAt: Date?
}

extension StatuspageSummaryDTO {
    /// Map the wire DTO to domain types using the forgiving status decoder
    /// (unknown enum values → `.operational` per AR §AD6).
    func toDomain() -> StatusPageSummary {
        let components = self.components.map { dto in
            StatusComponent(
                id: dto.id,
                name: dto.name,
                status: ClaudeServiceStatus(forgiving: dto.status),
                groupId: dto.groupId,
                updatedAt: dto.updatedAt
            )
        }
        let incidents = self.incidents.map { dto in
            StatusIncident(
                id: dto.id,
                name: dto.name,
                status: dto.status,
                impact: dto.impact,
                shortlink: dto.shortlink,
                updatedAt: dto.updatedAt
            )
        }
        return StatusPageSummary(components: components, incidents: incidents)
    }
}
