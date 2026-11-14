const os = require('node:os');
const express = require('express');

function toTodo(row) {
  return row && { id: row.id, title: row.title, done: !!row.done, createdAt: row.created_at };
}

function createApp(db) {
  const app = express();
  app.use(express.json());

  // Shows where the code is actually running: the point of the demo.
  app.get('/health', (_req, res) => {
    res.json({
      ok: true,
      platform: `${os.type()} ${os.arch()}`,
      node: process.version,
      sqlite: db.prepare('select sqlite_version() as v').get().v,
      env: process.env.APP_ENV || 'unset',
    });
  });

  app.get('/todos', (_req, res) => {
    res.json(db.prepare('SELECT * FROM todos ORDER BY id').all().map(toTodo));
  });

  app.post('/todos', (req, res) => {
    const title = typeof req.body?.title === 'string' ? req.body.title.trim() : '';
    if (!title) return res.status(400).json({ error: 'title is required' });
    const { lastInsertRowid } = db.prepare('INSERT INTO todos (title) VALUES (?)').run(title);
    res.status(201).json(toTodo(db.prepare('SELECT * FROM todos WHERE id = ?').get(lastInsertRowid)));
  });

  app.patch('/todos/:id', (req, res) => {
    const existing = db.prepare('SELECT * FROM todos WHERE id = ?').get(req.params.id);
    if (!existing) return res.status(404).json({ error: 'not found' });
    const done = req.body?.done === undefined ? existing.done : req.body.done ? 1 : 0;
    const title = typeof req.body?.title === 'string' && req.body.title.trim() ? req.body.title.trim() : existing.title;
    db.prepare('UPDATE todos SET title = ?, done = ? WHERE id = ?').run(title, done, existing.id);
    res.json(toTodo(db.prepare('SELECT * FROM todos WHERE id = ?').get(existing.id)));
  });

  app.delete('/todos/:id', (req, res) => {
    const { changes } = db.prepare('DELETE FROM todos WHERE id = ?').run(req.params.id);
    if (!changes) return res.status(404).json({ error: 'not found' });
    res.status(204).end();
  });

  return app;
}

module.exports = { createApp };
