var __require = /* @__PURE__ */ ((x) => typeof require !== "undefined" ? require : typeof Proxy !== "undefined" ? new Proxy(x, {
  get: (a, b) => (typeof require !== "undefined" ? require : a)[b]
}) : x)(function(x) {
  if (typeof require !== "undefined") return require.apply(this, arguments);
  throw Error('Dynamic require of "' + x + '" is not supported');
});

// src/memory/EntityStore.ts
import { DatabaseSync } from "sqlite";
var SCHEMA = `
CREATE TABLE IF NOT EXISTS state_entities (
  entity_id   TEXT PRIMARY KEY,
  name        TEXT NOT NULL DEFAULT '',
  data_json   TEXT NOT NULL DEFAULT '{}',
  updated_at  REAL NOT NULL,
  created_at  REAL NOT NULL
);
`;
var SQLiteEntityStore = class {
  db;
  /**
   * Create a new SQLiteEntityStore, initializing the schema.
   * 创建新的 SQLiteEntityStore，初始化 schema。
   *
   * @param dbPath - Path to the SQLite database file. / SQLite 数据库文件路径
   */
  constructor(dbPath) {
    this.db = new DatabaseSync(dbPath);
    this.db.exec(SCHEMA);
  }
  /**
   * Insert or update an entity (upsert by entityId).
   * 插入或更新实体（按 entityId 执行 upsert）。
   *
   * Strips the recordChange method before JSON serialization.
   * 在 JSON 序列化前移除 recordChange 方法。
   *
   * @param entity - StateEntity to persist. / 要持久化的 StateEntity
   */
  async upsert(entity) {
    const stmt = this.db.prepare(`
      INSERT INTO state_entities (entity_id, name, data_json, updated_at, created_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(entity_id) DO UPDATE SET
        name = excluded.name,
        data_json = excluded.data_json,
        updated_at = excluded.updated_at
    `);
    const { ...entityData } = entity;
    stmt.run(
      entity.entityId,
      entity.name,
      JSON.stringify({
        facts: entity.facts,
        summary: entity.summary,
        metrics: entity.metrics,
        intent: entity.intent,
        todos: entity.todos,
        risks: entity.risks,
        history: entity.history,
        dependsOn: entity.dependsOn,
        usedBy: entity.usedBy
      }),
      entity.updatedAt,
      entity.createdAt
    );
  }
  /**
   * Get an entity by ID.
   * 按 ID 获取实体。
   *
   * @param entityId - Unique entity identifier. / 唯一实体标识符
   * @returns StateEntity or null if not found. / StateEntity 或未找到时为 null
   */
  async get(entityId) {
    const stmt = this.db.prepare("SELECT * FROM state_entities WHERE entity_id = ?");
    const row = stmt.get(entityId);
    if (!row) return null;
    return this.rowToEntity(row);
  }
  /**
   * List all entities, ordered by name.
   * 列出所有实体，按名称排序。
   *
   * @returns Array of all StateEntity objects. / 所有 StateEntity 对象的数组
   */
  async list() {
    const stmt = this.db.prepare("SELECT * FROM state_entities ORDER BY name");
    const rows = stmt.all();
    return rows.map((r) => this.rowToEntity(r));
  }
  /**
   * Delete an entity by ID.
   * 按 ID 删除实体。
   *
   * @param entityId - Entity ID to delete. / 要删除的实体 ID
   */
  async delete(entityId) {
    this.db.prepare("DELETE FROM state_entities WHERE entity_id = ?").run(entityId);
  }
  /** Close the database connection. / 关闭数据库连接 */
  close() {
    this.db.close();
  }
  /**
   * Convert a raw SQLite row to a StateEntity with built-in recordChange.
   * 将原始 SQLite 行转换为包含内置 recordChange 方法的 StateEntity。
   *
   * @param row - Raw database row. / 原始数据库行
   * @returns StateEntity instance. / StateEntity 实例
   */
  rowToEntity(row) {
    const data = typeof row.data_json === "string" ? JSON.parse(row.data_json) : {};
    const now = Date.now() / 1e3;
    const entity = {
      entityId: row.entity_id,
      name: row.name ?? "",
      facts: data.facts ?? {},
      summary: data.summary ?? "",
      metrics: data.metrics ?? {},
      intent: data.intent ?? "",
      todos: data.todos ?? [],
      risks: data.risks ?? [],
      history: data.history ?? [],
      dependsOn: data.dependsOn ?? [],
      usedBy: data.usedBy ?? [],
      updatedAt: row.updated_at ?? now,
      createdAt: row.created_at ?? now,
      recordChange(field, key, oldValue, newValue, source) {
        this.history.push({
          timestamp: Date.now() / 1e3,
          field,
          key,
          oldValue,
          newValue,
          source: source ?? ""
        });
        this.updatedAt = Date.now() / 1e3;
      }
    };
    return entity;
  }
};

export {
  __require,
  SQLiteEntityStore
};
