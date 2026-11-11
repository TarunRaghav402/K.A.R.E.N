/**
 * In-memory Mock D1 Database for local unit & integration testing.
 */

export class MockD1Database {
  private tables: Record<string, any[]> = {
    devices: [],
    pairing_sessions: [],
    notification_requests: [],
  };

  prepare(query: string) {
    return new MockD1PreparedStatement(query, this.tables);
  }
}

class MockD1PreparedStatement {
  private params: any[] = [];

  constructor(private query: string, private tables: Record<string, any[]>) {}

  bind(...values: any[]) {
    this.params = values;
    return this;
  }

  async first<T = any>(): Promise<T | null> {
    const results = await this.execute();
    return (results[0] as T) || null;
  }

  async all<T = any>(): Promise<{ results: T[]; meta: any }> {
    const results = await this.execute();
    return { results: results as T[], meta: { changes: results.length } };
  }

  async run(): Promise<{ meta: { changes: number } }> {
    const changes = await this.executeMutation();
    return { meta: { changes } };
  }

  private async execute(): Promise<any[]> {
    const q = this.query.replace(/\s+/g, " ").trim();

    if (q.includes("FROM devices WHERE device_id = ? AND revoked = 0")) {
      return this.tables.devices.filter(
        (d) => d.device_id === this.params[0] && d.revoked === 0
      );
    }
    if (q.includes("FROM devices WHERE revoked = 0")) {
      return this.tables.devices.filter((d) => d.revoked === 0);
    }
    if (q.includes("COUNT(*) as count FROM devices WHERE revoked = 0")) {
      const count = this.tables.devices.filter((d) => d.revoked === 0).length;
      return [{ count }];
    }
    if (q.includes("COUNT(*) as count FROM notification_requests")) {
      const count = this.tables.notification_requests.filter((r) =>
        ["STORED", "NOTIFIED", "SENT", "DELIVERED", "WAITING"].includes(r.status)
      ).length;
      return [{ count }];
    }
    if (q.includes("FROM pairing_sessions WHERE session_id = ?")) {
      return this.tables.pairing_sessions.filter(
        (s) => s.session_id === this.params[0]
      );
    }
    if (q.includes("FROM pairing_sessions WHERE pairing_code = ?")) {
      return this.tables.pairing_sessions.filter(
        (s) => s.pairing_code === this.params[0] && s.expires_at > this.params[1]
      );
    }
    if (q.includes("FROM notification_requests WHERE request_id = ?")) {
      return this.tables.notification_requests.filter(
        (r) => r.request_id === this.params[0]
      );
    }
    if (q.includes("FROM notification_requests WHERE idempotency_key = ?")) {
      return this.tables.notification_requests.filter(
        (r) => r.idempotency_key === this.params[0]
      );
    }
    if (q.includes("FROM notification_requests WHERE status = 'RESPONDED'")) {
      return this.tables.notification_requests.filter(
        (r) => r.status === "RESPONDED"
      );
    }
    if (q.includes("FROM notification_requests WHERE status IN")) {
      if (q.includes("expires_at > ?")) {
        return this.tables.notification_requests.filter(
          (r) =>
            ["STORED", "NOTIFIED", "SENT", "DELIVERED", "WAITING"].includes(
              r.status
            ) && r.expires_at > this.params[0]
        );
      }
      if (q.includes("expires_at <= ?")) {
        return this.tables.notification_requests.filter(
          (r) =>
            ["STORED", "NOTIFIED", "SENT", "DELIVERED", "WAITING"].includes(
              r.status
            ) && r.expires_at <= this.params[0]
        );
      }
    }

    return [];
  }

  private async executeMutation(): Promise<number> {
    const q = this.query.replace(/\s+/g, " ").trim();

    if (q.startsWith("INSERT INTO pairing_sessions")) {
      this.tables.pairing_sessions.push({
        session_id: this.params[0],
        pairing_code: this.params[1],
        qr_payload: this.params[2],
        mac_id: this.params[3],
        mac_name: this.params[4],
        created_at: this.params[5],
        expires_at: this.params[6],
        is_paired: 0,
        paired_device_id: null,
      });
      return 1;
    }

    if (q.startsWith("INSERT INTO devices")) {
      const idx = this.tables.devices.findIndex((d) => d.device_id === this.params[0]);
      const record = {
        device_id: this.params[0],
        device_name: this.params[1],
        device_token_hash: this.params[2],
        fcm_token: this.params[3],
        paired_at: this.params[4],
        last_seen_at: this.params[5],
        revoked: 0,
      };
      if (idx >= 0) {
        this.tables.devices[idx] = record;
      } else {
        this.tables.devices.push(record);
      }
      return 1;
    }

    if (q.startsWith("UPDATE pairing_sessions")) {
      const session = this.tables.pairing_sessions.find(
        (s) => s.session_id === this.params[1]
      );
      if (session) {
        session.is_paired = 1;
        session.paired_device_id = this.params[0];
        return 1;
      }
      return 0;
    }

    if (q.startsWith("INSERT INTO notification_requests")) {
      this.tables.notification_requests.push({
        request_id: this.params[0],
        idempotency_key: this.params[1],
        type: this.params[2],
        title: this.params[3],
        message: this.params[4],
        details: this.params[5],
        actions_json: this.params[6],
        status: "SENT",
        created_at: this.params[7],
        stored_at: this.params[8],
        sent_at: this.params[9],
        expires_at: this.params[10],
        attempt_count: 0,
        outcome: null,
        reply_text: null,
        responder_device_id: null,
        lease_owner: null,
        lease_expires_at: null,
      });
      return 1;
    }

    if (q.includes("UPDATE notification_requests SET status = 'DELIVERED'")) {
      const req = this.tables.notification_requests.find(
        (r) => r.request_id === this.params[1]
      );
      if (req) {
        req.status = "DELIVERED";
        req.delivered_at = this.params[0];
        return 1;
      }
      return 0;
    }

    if (q.includes("SET status = 'RESPONDED'")) {
      const req = this.tables.notification_requests.find(
        (r) => r.request_id === this.params[4]
      );
      if (req) {
        req.status = "RESPONDED";
        req.outcome = this.params[0];
        req.reply_text = this.params[1];
        req.responder_device_id = this.params[2];
        req.responded_at = this.params[3];
        return 1;
      }
      return 0;
    }

    if (q.includes("SET status = 'CANCELLED'")) {
      const req = this.tables.notification_requests.find(
        (r) => r.request_id === this.params[1]
      );
      if (req) {
        req.status = "CANCELLED";
        req.outcome = "CANCELLED";
        req.responded_at = this.params[0];
        return 1;
      }
      return 0;
    }

    if (q.includes("SET status = 'EXPIRED'")) {
      let changes = 0;
      for (const r of this.tables.notification_requests) {
        if (
          ["STORED", "NOTIFIED", "SENT", "DELIVERED", "WAITING"].includes(r.status) &&
          r.expires_at <= this.params[0]
        ) {
          r.status = "EXPIRED";
          r.outcome = "EXPIRED";
          r.responded_at = this.params[0];
          changes++;
        }
      }
      return changes;
    }

    if (q.includes("SET lease_owner = ?")) {
      const req = this.tables.notification_requests.find(
        (r) => r.request_id === this.params[2]
      );
      if (req) {
        req.lease_owner = this.params[0];
        req.lease_expires_at = this.params[1];
        req.attempt_count = (req.attempt_count || 0) + 1;
        return 1;
      }
      return 0;
    }

    if (q.includes("UPDATE notification_requests SET status = ?, synced_at = ?")) {
      const req = this.tables.notification_requests.find(
        (r) => r.request_id === this.params[3]
      );
      if (req) {
        req.status = this.params[0];
        req.synced_at = this.params[1];
        req.completed_at = this.params[2];
        return 1;
      }
      return 0;
    }

    if (q.includes("UPDATE devices SET revoked = 1")) {
      const dev = this.tables.devices.find((d) => d.device_id === this.params[0]);
      if (dev) {
        dev.revoked = 1;
        return 1;
      }
      return 0;
    }

    if (q.includes("UPDATE devices SET last_seen_at = ?")) {
      const dev = this.tables.devices.find((d) => d.device_id === this.params[1]);
      if (dev) {
        dev.last_seen_at = this.params[0];
        return 1;
      }
      return 0;
    }

    return 0;
  }
}
