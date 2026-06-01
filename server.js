'use strict';

const express  = require('express');
const session  = require('express-session');
const bcrypt   = require('bcrypt');
const { Pool } = require('pg');
const path     = require('path');
const fs       = require('fs');

// ─── Database ────────────────────────────────────────────────────────────────

const db = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false,
});

// ─── Rate limiting helpers (in-memory, no extra dependency) ──────────────────

// RSVP: max 3 per IP per 10 minutes
const rsvpLimiter = new Map(); // ip → { count, resetAt }
function checkRsvpRate(ip) {
  const now = Date.now();
  const entry = rsvpLimiter.get(ip);
  if (!entry || now > entry.resetAt) {
    rsvpLimiter.set(ip, { count: 1, resetAt: now + 10 * 60 * 1000 });
    return true;
  }
  if (entry.count >= 3) return false;
  entry.count++;
  return true;
}

// Login: 5 failed attempts → 15-minute lockout
const loginLimiter = new Map(); // ip → { failures, lockedUntil }
function checkLoginRate(ip) {
  const now = Date.now();
  const entry = loginLimiter.get(ip);
  if (!entry) return true;
  if (entry.lockedUntil && now < entry.lockedUntil) return false;
  if (entry.lockedUntil && now >= entry.lockedUntil) {
    loginLimiter.delete(ip);
    return true;
  }
  return true;
}
function recordLoginFailure(ip) {
  const entry = loginLimiter.get(ip) || { failures: 0 };
  entry.failures++;
  if (entry.failures >= 5) entry.lockedUntil = Date.now() + 15 * 60 * 1000;
  loginLimiter.set(ip, entry);
}
function clearLoginFailures(ip) { loginLimiter.delete(ip); }

// ─── App setup ───────────────────────────────────────────────────────────────

const app = express();

app.set('trust proxy', 1); // Render sits behind a proxy

app.use(express.json());
app.use(express.urlencoded({ extended: false }));

app.use(session({
  secret:            process.env.SESSION_SECRET || 'dev-secret-change-me',
  resave:            false,
  saveUninitialized: false,
  cookie: {
    httpOnly: true,
    secure:   process.env.NODE_ENV === 'production',
    sameSite: 'lax',
    maxAge:   8 * 60 * 60 * 1000, // 8 hours
  },
}));

// Serve all static files from the project root:
// index.html, all images (IMG_*.jpeg, IMG_*.png), etc.
app.use(express.static(path.join(__dirname)));

// ─── Auth middleware ──────────────────────────────────────────────────────────

function requireAuth(req, res, next) {
  if (req.session && req.session.authenticated) return next();
  if (req.path.startsWith('/api/')) return res.status(401).json({ error: 'Unauthorized' });
  return res.redirect('/login');
}

// ─── API: Submit RSVP ────────────────────────────────────────────────────────

app.post('/api/rsvp', async (req, res) => {
  const ip = req.ip;
  if (!checkRsvpRate(ip)) {
    return res.status(429).json({ error: 'Too many RSVPs from this device. Please wait a few minutes.' });
  }

  const firstName   = String(req.body.firstName   || '').trim().slice(0, 80);
  const lastName    = String(req.body.lastName    || '').trim().slice(0, 80);
  const email       = String(req.body.email       || '').trim().slice(0, 255);
  const songRequest = String(req.body.songRequest || '').trim().slice(0, 200);

  if (!firstName || !lastName) {
    return res.status(400).json({ error: 'First and last name are required.' });
  }
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ error: 'Please enter a valid email address.' });
  }

  try {
    await db.query(
      `INSERT INTO rsvps (first_name, last_name, email, song_request)
       VALUES ($1, $2, $3, $4)`,
      [firstName, lastName, email || null, songRequest || null]
    );
    return res.json({ ok: true, message: "Thank you! We can't wait to celebrate with you." });
  } catch (err) {
    console.error('RSVP insert error:', err);
    return res.status(500).json({ error: 'Something went wrong. Please try again.' });
  }
});

// ─── Dashboard login ─────────────────────────────────────────────────────────

app.get('/login', (req, res) => {
  if (req.session && req.session.authenticated) return res.redirect('/dashboard');
  res.sendFile(path.join(__dirname, 'views', 'login.html'));
});

app.post('/api/login', async (req, res) => {
  const ip       = req.ip;
  const password = String(req.body.password || '');

  if (!checkLoginRate(ip)) {
    return res.redirect('/login?error=locked');
  }

  try {
    const result = await db.query('SELECT password_hash FROM admin_credentials WHERE id = 1');
    if (result.rows.length === 0) {
      return res.redirect('/login?error=1');
    }
    const match = await bcrypt.compare(password, result.rows[0].password_hash);
    if (!match) {
      recordLoginFailure(ip);
      return res.redirect('/login?error=1');
    }
    clearLoginFailures(ip);
    req.session.authenticated = true;
    req.session.save(() => res.redirect('/dashboard'));
  } catch (err) {
    console.error('Login error:', err);
    return res.redirect('/login?error=1');
  }
});

app.post('/api/logout', (req, res) => {
  req.session.destroy(() => res.redirect('/login'));
});

// ─── Dashboard ───────────────────────────────────────────────────────────────

app.get('/dashboard', requireAuth, (req, res) => {
  res.sendFile(path.join(__dirname, 'views', 'dashboard.html'));
});

// JSON data endpoint (consumed by dashboard.html JS)
app.get('/api/rsvps', requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT id, first_name, last_name, email, song_request, submitted_at
       FROM rsvps
       ORDER BY submitted_at DESC`
    );
    const now  = new Date();
    const week = new Date(now - 7 * 24 * 60 * 60 * 1000);
    return res.json({
      total:       result.rows.length,
      thisWeek:    result.rows.filter(r => new Date(r.submitted_at) >= week).length,
      latest:      result.rows[0] ? result.rows[0].submitted_at : null,
      rsvps:       result.rows,
    });
  } catch (err) {
    console.error('RSVP fetch error:', err);
    return res.status(500).json({ error: 'Could not load RSVPs.' });
  }
});

// CSV export
app.get('/api/rsvps/export.csv', requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT id, first_name, last_name, email, song_request, submitted_at
       FROM rsvps
       ORDER BY submitted_at DESC`
    );

    const esc = v => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const today = new Date().toISOString().slice(0, 10);

    const header = ['ID', 'First Name', 'Last Name', 'Email', 'Song Request', 'Submitted At'].map(esc).join(',');
    const rows   = result.rows.map(r =>
      [r.id, r.first_name, r.last_name, r.email ?? '', r.song_request ?? '', r.submitted_at].map(esc).join(',')
    );

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename="rsvps-${today}.csv"`);
    return res.send([header, ...rows].join('\r\n'));
  } catch (err) {
    console.error('CSV export error:', err);
    return res.status(500).send('Export failed.');
  }
});

// ─── Startup ─────────────────────────────────────────────────────────────────

async function start() {
  // Run idempotent schema migration
  const schema = fs.readFileSync(path.join(__dirname, 'db', 'schema.sql'), 'utf8');
  await db.query(schema);
  console.log('Database schema ready.');

  // Sync dashboard password from env on every boot
  if (process.env.DASHBOARD_PASSWORD) {
    const hash = await bcrypt.hash(process.env.DASHBOARD_PASSWORD, 12);
    await db.query(
      'INSERT INTO admin_credentials (id, password_hash) VALUES (1, $1) ON CONFLICT (id) DO UPDATE SET password_hash = EXCLUDED.password_hash',
      [hash]
    );
    console.log('Dashboard credentials initialised.');
  }

  const port = process.env.PORT || 3000;
  app.listen(port, () => console.log(`Server running on port ${port}`));
}

start().catch(err => {
  console.error('Startup failed:', err);
  process.exit(1);
});
