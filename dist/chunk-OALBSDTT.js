var p=(n=>typeof require<"u"?require:typeof Proxy<"u"?new Proxy(n,{get:(t,e)=>(typeof require<"u"?require:t)[e]}):n)(function(n){if(typeof require<"u")return require.apply(this,arguments);throw Error('Dynamic require of "'+n+'" is not supported')});import{DatabaseSync as m}from"sqlite";var E=`
CREATE TABLE IF NOT EXISTS state_entities (
  entity_id   TEXT PRIMARY KEY,
  name        TEXT NOT NULL DEFAULT '',
  data_json   TEXT NOT NULL DEFAULT '{}',
  updated_at  REAL NOT NULL,
  created_at  REAL NOT NULL
);
`,a=class{db;constructor(t){this.db=new m(t),this.db.exec(E)}async upsert(t){let e=this.db.prepare(`
      INSERT INTO state_entities (entity_id, name, data_json, updated_at, created_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(entity_id) DO UPDATE SET
        name = excluded.name,
        data_json = excluded.data_json,
        updated_at = excluded.updated_at
    `),{...s}=t;e.run(t.entityId,t.name,JSON.stringify({facts:t.facts,summary:t.summary,metrics:t.metrics,intent:t.intent,todos:t.todos,risks:t.risks,history:t.history,dependsOn:t.dependsOn,usedBy:t.usedBy}),t.updatedAt,t.createdAt)}async get(t){let s=this.db.prepare("SELECT * FROM state_entities WHERE entity_id = ?").get(t);return s?this.rowToEntity(s):null}async list(){return this.db.prepare("SELECT * FROM state_entities ORDER BY name").all().map(s=>this.rowToEntity(s))}async delete(t){this.db.prepare("DELETE FROM state_entities WHERE entity_id = ?").run(t)}close(){this.db.close()}rowToEntity(t){let e=typeof t.data_json=="string"?JSON.parse(t.data_json):{},s=Date.now()/1e3;return{entityId:t.entity_id,name:t.name??"",facts:e.facts??{},summary:e.summary??"",metrics:e.metrics??{},intent:e.intent??"",todos:e.todos??[],risks:e.risks??[],history:e.history??[],dependsOn:e.dependsOn??[],usedBy:e.usedBy??[],updatedAt:t.updated_at??s,createdAt:t.created_at??s,recordChange(i,d,r,o,c){this.history.push({timestamp:Date.now()/1e3,field:i,key:d,oldValue:r,newValue:o,source:c??""}),this.updatedAt=Date.now()/1e3}}}};export{p as a,a as b};
