import type { Database } from "bun:sqlite";

export function getSetting(db: Database, key: string): string | null {
	const row = db.query(`SELECT value FROM settings WHERE key = ?`).get(key) as { value: string } | null;
	return row?.value ?? null;
}

export function setSetting(db: Database, key: string, value: string): void {
	db.query(
		`INSERT INTO settings (key, value)
		 VALUES (?, ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
	).run(key, value);
}
