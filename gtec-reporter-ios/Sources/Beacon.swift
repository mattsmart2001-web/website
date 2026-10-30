import Foundation

/// Site details, kept in one place. Both values are public: the anon key is
/// the same one the website ships in `gtec-config.js`, and a beacon is
/// authorised by the driver's pairing token, not by this.
enum Site {
    static let supabaseURL = "https://wtryzoabpkqtucfpmbnn.supabase.co"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind0cnl6b2FicGtxdHVjZnBtYm5uIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA0MTg0MjMsImV4cCI6MjA5NTk5NDQyM30.Jpx_23mxUsiS5Ke2MCZKOKBu09bH1XuViY6heAB-jds"
}

/// Posts one car's state to GTEC.
///
/// Deliberately stateless and deliberately dumb: a beacon is a snapshot of
/// the last packet, never an aggregate. Everything derived, the running
/// order, the gaps, the distance round the lap, is the website's job, so
/// there is nothing here that can drift out of step with what the server
/// believes.
struct Beacon {

    struct Reply {
        let ok: Bool
        /// False when there is no race on, or the driver is not entered.
        let reporting: Bool
        /// How long to wait before the next beacon, as the server sees it.
        let nextMs: Int
        let error: String?
    }

    /// Returned when the request itself failed, as opposed to being refused.
    private static func unreachable(_ msg: String) -> Reply {
        Reply(ok: false, reporting: false, nextMs: 15_000, error: msg)
    }

    static func send(token: String, sample: GT7Packet.Sample, lapMs: Int?) async -> Reply {
        var body: [String: Any] = [
            "p_token": token,
            "p_lap": sample.lap,
            "p_x": sample.x,
            // Elevation. The map shades the track by height and a position
            // without it cannot be reconstructed later, so a phone acting
            // as the shape source would otherwise cost the outline its
            // relief.
            "p_y": sample.y,
            "p_z": sample.z,
            "p_speed_kph": sample.speedKph,
            "p_on_track": sample.onTrack,
            // Which app is reporting, so the live page can say so.
            "p_client": "ios",
        ]
        if let lapMs { body["p_lap_ms"] = lapMs }
        if let v = sample.lastLapMs { body["p_last_lap_ms"] = v }
        if let v = sample.bestLapMs { body["p_best_lap_ms"] = v }
        if let v = sample.fuelPercent { body["p_fuel_pct"] = v }
        if sample.lapsInRace > 0 { body["p_laps_in_race"] = sample.lapsInRace }

        guard let url = URL(string: "\(Site.supabaseURL)/rest/v1/rpc/live_beacon"),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return unreachable("Could not build the request") }

        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Site.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(Site.anonKey)", forHTTPHeaderField: "Authorization")

        do {
            let (out, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else { return unreachable("Server said \(code)") }

            let j = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:]
            return Reply(
                ok: j["ok"] as? Bool ?? false,
                reporting: j["reporting"] as? Bool ?? false,
                // Honour the server's pacing: it backs the reporter off to
                // fifteen seconds while the car sits in the menus, which is
                // where most of the pointless traffic would come from.
                nextMs: j["next_ms"] as? Int ?? 3_000,
                error: j["error"] as? String
            )
        } catch {
            // A dropped beacon is not worth queueing. A stale position shown
            // as live is worse than a gap the page can age out honestly.
            return unreachable(error.localizedDescription)
        }
    }
}
