const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { openDb } = require('../src/db');
const { createApp } = require('../src/app');

let server, base, db;

before(async () => {
  db = openDb(':memory:');
  server = createApp(db).listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => { server.close(); db.close(); });

const json = (method, path, body) =>
  fetch(base + path, { method, headers: { 'content-type': 'application/json' }, body: body && JSON.stringify(body) });

test('health reports runtime info', async () => {
  const res = await json('GET', '/health');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.match(body.sqlite, /^\d+\.\d+/);
});

test('create, list, update, delete a todo', async () => {
  const created = await (await json('POST', '/todos', { title: '  write tests  ' })).json();
  assert.equal(created.title, 'write tests');
  assert.equal(created.done, false);

  const list = await (await json('GET', '/todos')).json();
  assert.equal(list.length, 1);

  const updated = await (await json('PATCH', `/todos/${created.id}`, { done: true })).json();
  assert.equal(updated.done, true);

  assert.equal((await json('DELETE', `/todos/${created.id}`)).status, 204);
  assert.equal((await json('DELETE', `/todos/${created.id}`)).status, 404);
});

test('rejects a todo without a title', async () => {
  assert.equal((await json('POST', '/todos', { title: '   ' })).status, 400);
});
