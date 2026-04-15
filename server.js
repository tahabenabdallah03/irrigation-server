const http = require('http');
const { Server } = require("socket.io");
const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const cors = require('cors');
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const SECRET_KEY = process.env.SECRET_KEY || "SMART_IRRIGATION_SECRET";
const ALLOW_REGISTER = (process.env.ALLOW_REGISTER || 'false').toLowerCase() === 'true';
const rawBcryptRounds = Number.parseInt(process.env.AUTH_BCRYPT_ROUNDS || '12', 10);
const AUTH_BCRYPT_ROUNDS = Number.isInteger(rawBcryptRounds) && rawBcryptRounds > 0
  ? rawBcryptRounds
  : 12;
const DEFAULT_USER_EMAIL = (process.env.SINGLE_USER_EMAIL || 'admin@iot.com').trim().toLowerCase();
const DEFAULT_USER_PASSWORD = process.env.SINGLE_USER_PASSWORD || '';
const rawLoginWindowMs = Number.parseInt(process.env.LOGIN_WINDOW_MS || '30000', 10);
const LOGIN_WINDOW_MS = Number.isInteger(rawLoginWindowMs) && rawLoginWindowMs > 0
  ? rawLoginWindowMs
  : 30 * 1000;
const rawLoginMaxFailures = Number.parseInt(process.env.LOGIN_MAX_FAILURES || '5', 10);
const LOGIN_MAX_FAILURES = Number.isInteger(rawLoginMaxFailures) && rawLoginMaxFailures > 0
  ? rawLoginMaxFailures
  : 5;
const rawTankCapacityLiters = Number.parseFloat(process.env.TANK_CAPACITY_L || '1000');
const TANK_CAPACITY_L = Number.isFinite(rawTankCapacityLiters) && rawTankCapacityLiters > 0
  ? rawTankCapacityLiters
  : 1000;
const rawMaxDosingSteps = Number.parseInt(process.env.MAX_DOSING_STEPS || '2000000', 10);
const MAX_DOSING_STEPS = Number.isInteger(rawMaxDosingSteps) && rawMaxDosingSteps > 0
  ? rawMaxDosingSteps
  : 2000000;
const DOSING_PRODUCTS = ['A', 'B', 'C'];

if (SECRET_KEY === 'SMART_IRRIGATION_SECRET') {
  console.warn('Using default SECRET_KEY. Set SECRET_KEY in production.');
}

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST']
  }
});
const db = new sqlite3.Database('./database.db');

app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const loginAttempts = new Map();
const lastAlertsSent = new Map();

const normalizeEmail = (value) => (value || '').toString().trim().toLowerCase();

const getClientIp = (req) => {
  const xff = req.headers['x-forwarded-for'];
  if (typeof xff === 'string' && xff.trim()) {
    return xff.split(',')[0].trim();
  }
  return req.ip || req.connection?.remoteAddress || 'unknown';
};

const getLoginAttemptState = (ip) => {
  const now = Date.now();
  const current = loginAttempts.get(ip);

  if (!current || (now - current.firstFailureAt) > LOGIN_WINDOW_MS) {
    const freshState = {
      count: 0,
      firstFailureAt: now,
      blockedUntil: 0
    };
    loginAttempts.set(ip, freshState);
    return freshState;
  }

  return current;
};

const isLoginBlocked = (ip) => {
  const state = loginAttempts.get(ip);
  if (!state) return false;

  if (state.blockedUntil && state.blockedUntil > Date.now()) {
    return true;
  }

  if (state.blockedUntil && state.blockedUntil <= Date.now()) {
    loginAttempts.delete(ip);
  }

  return false;
};

const registerLoginFailure = (ip) => {
  const state = getLoginAttemptState(ip);
  const now = Date.now();

  state.count += 1;

  if (state.count >= LOGIN_MAX_FAILURES) {
    state.blockedUntil = now + LOGIN_WINDOW_MS;
  }

  loginAttempts.set(ip, state);
};

const clearLoginFailures = (ip) => {
  loginAttempts.delete(ip);
};

const requireAuth = (req, res, next) => {
  const authHeader = (req.headers.authorization || '').toString();
  const token = authHeader.toLowerCase().startsWith('bearer ')
    ? authHeader.slice(7).trim()
    : null;

  if (!token) {
    return res.status(401).json({ error: 'Missing bearer token' });
  }

  jwt.verify(token, SECRET_KEY, (err, decoded) => {
    if (err) {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }

    req.user = decoded;
    return next();
  });
};

const buildAlertKey = (alert) => {
  const zoneId = toNullableNumber(alert?.zone_id) ?? 'global';
  const source = (alert?.source || 'UNKNOWN').toString().trim().toUpperCase();
  return `${source}:${zoneId}`;
};

const filterUniqueAlertChanges = (alerts) => {
  if (!Array.isArray(alerts)) return [];

  const emitted = [];

  alerts.forEach((alert) => {
    const message = (alert?.message || '').toString().trim();
    if (!message) return;

    const normalized = {
      zone_id: toNullableNumber(alert?.zone_id),
      zone_name: (alert?.zone_name || '').toString().trim(),
      message,
      level: (alert?.level || 'WARNING').toString().trim().toUpperCase(),
      source: (alert?.source || 'LABVIEW').toString().trim().toUpperCase()
    };
    const key = buildAlertKey(normalized);
    const signature = JSON.stringify({
      message: normalized.message,
      level: normalized.level,
      source: normalized.source
    });

    if (lastAlertsSent.get(key) === signature) {
      return;
    }

    lastAlertsSent.set(key, signature);
    emitted.push(normalized);
  });

  return emitted;
};

const clearLastAlertSignatureForZone = (zoneId, source = 'LABVIEW') => {
  const key = buildAlertKey({ zone_id: zoneId, source });
  lastAlertsSent.delete(key);
};

io.use((socket, next) => {
  const authToken = socket.handshake?.auth?.token;
  const authHeader = (socket.handshake?.headers?.authorization || '').toString();
  const bearerFromHeader = authHeader.toLowerCase().startsWith('bearer ')
    ? authHeader.slice(7).trim()
    : null;
  const token = authToken || bearerFromHeader;

  if (!token) {
    return next(new Error('Missing bearer token'));
  }

  jwt.verify(token, SECRET_KEY, (err, decoded) => {
    if (err) return next(new Error('Invalid token'));
    socket.user = decoded;
    return next();
  });
});

const HISTORY_MODE_VALUES = new Set(['events', 'periodic', 'mixed']);

const normalizeHistoryMode = (raw) => {
  const v = (raw ?? '').toString().trim().toLowerCase();
  return HISTORY_MODE_VALUES.has(v) ? v : 'mixed';
};

const generateSnapshotBatchId = () => {
  // sortable id, unique enough for this app
  return `SNAP-${Date.now()}-${Math.random().toString(16).slice(2)}`;
};

const buildHistoryRealtimePayload = (callback) => {
  db.get(
    `SELECT * FROM environment ORDER BY created_at DESC, id DESC LIMIT 1`,
    (envErr, environmentRow) => {
      if (envErr) return callback(envErr);

      db.all(
        `
          SELECT
            z.id,
            COALESCE(NULLIF(TRIM(z.name), ''), 'Zone ' || z.id) AS zone_name,
            COALESCE(z.humidity, 0) AS humidity,
            COALESCE(z.temperature, 0) AS temperature,
            COALESCE(z.gaz, 0) AS gaz,
            COALESCE(z.light, 0) AS light,
            COALESCE(z.valve, 0) AS valve,
            COALESCE(NULLIF(TRIM(z.ev_mode), ''), 'AUTO') AS ev_mode,
            zaa.message AS latest_alert_message,
            zaa.level AS latest_alert_level,
            zaa.updated_at AS latest_alert_created_at
          FROM zones z
          LEFT JOIN zone_active_alerts zaa ON zaa.zone_id = z.id
          ORDER BY z.id ASC
        `,
        (zonesErr, latestZonesRows) => {
          if (zonesErr) return callback(zonesErr);

          db.all(
            `
              SELECT id, zone_id, zone_name, message, level, source, created_at
              FROM zone_alerts
              ORDER BY created_at DESC, id DESC
              LIMIT 100
            `,
            (alertsErr, alertRows) => {
              if (alertsErr) return callback(alertsErr);

              callback(null, {
                environment: environmentRow || null,
                zones: latestZonesRows || [],
                alerts: alertRows || [],
                generated_at: new Date().toISOString()
              });
            }
          );
        }
      );
    }
  );
};

const emitHistoryRealtime = () => {
  buildHistoryRealtimePayload((err, payload) => {
    if (err) {
      console.error('history realtime emit error:', err.message);
      return;
    }

    io.emit('history-realtime', payload);
  });
};

const insertZoneHistorySnapshotIfChangedSql = `
  INSERT INTO zones_history (zone_id, humidity, temperature, gaz, light, valve, ev_mode)
  SELECT
    z.id,
    z.humidity,
    z.temperature,
    z.gaz,
    z.light,
    COALESCE(z.valve, 0) AS valve,
    COALESCE(z.ev_mode, 'AUTO') AS ev_mode
  FROM zones z
  WHERE z.id = ?
    AND NOT EXISTS (
      SELECT 1
      FROM (
        SELECT humidity, temperature, gaz, light, valve, ev_mode
        FROM zones_history
        WHERE zone_id = z.id
        ORDER BY created_at DESC, id DESC
        LIMIT 1
      ) last
      WHERE COALESCE(last.humidity, -999999) = COALESCE(z.humidity, -999999)
        AND COALESCE(last.temperature, -999999) = COALESCE(z.temperature, -999999)
        AND COALESCE(last.gaz, -999999) = COALESCE(z.gaz, -999999)
        AND COALESCE(last.light, -999999) = COALESCE(z.light, -999999)
        AND COALESCE(last.valve, -999999) = COALESCE(COALESCE(z.valve, 0), -999999)
        AND COALESCE(last.ev_mode, '') = COALESCE(z.ev_mode, '')
    )
`;

const insertZoneHistorySnapshotOnAlertChangeSql = `
  INSERT INTO zones_history (zone_id, humidity, temperature, gaz, light, valve, ev_mode)
  SELECT
    z.id,
    z.humidity,
    z.temperature,
    z.gaz,
    z.light,
    COALESCE(z.valve, 0) AS valve,
    COALESCE(z.ev_mode, 'AUTO') AS ev_mode
  FROM zones z
  WHERE z.id = ?
    AND ? <> ''
    AND COALESCE((SELECT message FROM zone_active_alerts WHERE zone_id = ?), '') <> ?
`;


const pickFirst = (obj, keys) => {
  for (const key of keys) {
    if (obj && obj[key] !== undefined && obj[key] !== null && obj[key] !== '') {
      return obj[key];
    }
  }
  return null;
};

const toNullableNumber = (value) => {
  if (value === undefined || value === null || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};

const clampNumber = (value, min, max) => {
  return Math.min(Math.max(value, min), max);
};

const normalizeDosingProductConfig = (rawEntry) => {
  if (!rawEntry || typeof rawEntry !== 'object') return null;

  const minMlPerL = toNullableNumber(
    pickFirst(rawEntry, ['min_ml_per_l', 'minMlPerL'])
  );
  const maxMlPerL = toNullableNumber(
    pickFirst(rawEntry, ['max_ml_per_l', 'maxMlPerL'])
  );
  const minMlLegacyAbs = toNullableNumber(
    pickFirst(rawEntry, ['min_ml', 'minMl'])
  );
  const maxMlLegacyAbs = toNullableNumber(
    pickFirst(rawEntry, ['max_ml', 'maxMl'])
  );

  return {
    dose_ml_per_l: toNullableNumber(rawEntry.dose_ml_per_l),
    min_ml_per_l: minMlPerL,
    max_ml_per_l: maxMlPerL,
    min_ml: minMlLegacyAbs,
    max_ml: maxMlLegacyAbs,
    rod_pitch_mm: toNullableNumber(rawEntry.rod_pitch_mm),
    steps_per_turn: toNullableNumber(rawEntry.steps_per_turn),
    ml_per_mm: toNullableNumber(rawEntry.ml_per_mm)
  };
};

const extractDosingConfigFromPayload = (body) => {
  const source = body && typeof body === 'object' && body.dosage_config && typeof body.dosage_config === 'object'
    ? body.dosage_config
    : body;

  if (!source || typeof source !== 'object') return null;

  const normalized = {};

  for (const product of DOSING_PRODUCTS) {
    const entry = normalizeDosingProductConfig(source[product]);
    if (!entry) return null;
    normalized[product] = entry;
  }

  return normalized;
};

const validateDosingConfig = (configByProduct) => {
  if (!configByProduct) return 'dosage_config invalide';

  for (const product of DOSING_PRODUCTS) {
    const config = configByProduct[product];
    if (!config) return `Configuration manquante pour le produit ${product}`;

    const {
      dose_ml_per_l,
      min_ml_per_l,
      max_ml_per_l,
      min_ml,
      max_ml,
      rod_pitch_mm,
      steps_per_turn,
      ml_per_mm
    } = config;

    const hasPerLiterBounds = min_ml_per_l != null || max_ml_per_l != null;
    const hasLegacyAbsoluteBounds = min_ml != null || max_ml != null;

    if (dose_ml_per_l == null || dose_ml_per_l < 0) {
      return `dose_ml_per_l invalide pour le produit ${product}`;
    }
    if (!hasPerLiterBounds && !hasLegacyAbsoluteBounds) {
      return `Bornes min/max manquantes pour le produit ${product}`;
    }

    if (hasPerLiterBounds) {
      if (min_ml_per_l == null || min_ml_per_l < 0) {
        return `min_ml_per_l invalide pour le produit ${product}`;
      }
      if (max_ml_per_l == null || max_ml_per_l < 0) {
        return `max_ml_per_l invalide pour le produit ${product}`;
      }
      if (max_ml_per_l < min_ml_per_l) {
        return `max_ml_per_l doit être >= min_ml_per_l pour le produit ${product}`;
      }
    }

    if (!hasPerLiterBounds && hasLegacyAbsoluteBounds) {
      if (min_ml == null || min_ml < 0) {
        return `min_ml invalide pour le produit ${product}`;
      }
      if (max_ml == null || max_ml < 0) {
        return `max_ml invalide pour le produit ${product}`;
      }
      if (max_ml < min_ml) {
        return `max_ml doit être >= min_ml pour le produit ${product}`;
      }
    }
    if (rod_pitch_mm == null || rod_pitch_mm <= 0) {
      return `rod_pitch_mm invalide pour le produit ${product}`;
    }
    if (steps_per_turn == null || steps_per_turn <= 0) {
      return `steps_per_turn invalide pour le produit ${product}`;
    }
    if (ml_per_mm == null || ml_per_mm <= 0) {
      return `ml_per_mm invalide pour le produit ${product}`;
    }
  }

  return null;
};

const computeDosingPlan = ({ waterLiters, configByProduct }) => {
  const safeWaterLiters = Math.max(0, toNullableNumber(waterLiters) ?? 0);
  const products = {};

  for (const product of DOSING_PRODUCTS) {
    const config = configByProduct[product];
    const theoreticalDoseMl = safeWaterLiters * config.dose_ml_per_l;
    const hasPerLiterBounds =
      config.min_ml_per_l != null && config.max_ml_per_l != null;
    const minDoseMlAbs = hasPerLiterBounds
      ? safeWaterLiters * config.min_ml_per_l
      : (config.min_ml ?? 0);
    const maxDoseMlAbs = hasPerLiterBounds
      ? safeWaterLiters * config.max_ml_per_l
      : (config.max_ml ?? 0);
    const doseMl = clampNumber(theoreticalDoseMl, minDoseMlAbs, maxDoseMlAbs);
    const courseMm = doseMl / config.ml_per_mm;
    const turns = courseMm / config.rod_pitch_mm;
    const stepsFloat = turns * config.steps_per_turn;
    const steps = Math.ceil(stepsFloat);

    if (!Number.isFinite(steps) || steps < 0) {
      throw new Error(`Calcul de steps invalide pour le produit ${product}`);
    }

    if (steps > MAX_DOSING_STEPS) {
      throw new Error(`Nombre de steps trop eleve pour le produit ${product}`);
    }

    products[product] = {
      theoretical_dose_ml: Number(theoreticalDoseMl.toFixed(6)),
      min_dose_ml_abs: Number(minDoseMlAbs.toFixed(6)),
      max_dose_ml_abs: Number(maxDoseMlAbs.toFixed(6)),
      target_dose_ml: Number(doseMl.toFixed(6)),
      course_mm: Number(courseMm.toFixed(6)),
      turns: Number(turns.toFixed(6)),
      steps_float: Number(stepsFloat.toFixed(6)),
      steps
    };
  }

  const totals = DOSING_PRODUCTS.reduce((acc, product) => {
    acc.target_dose_ml += products[product].target_dose_ml;
    acc.steps += products[product].steps;
    return acc;
  }, { target_dose_ml: 0, steps: 0 });

  totals.target_dose_ml = Number(totals.target_dose_ml.toFixed(6));

  return {
    water_liters: Number(safeWaterLiters.toFixed(6)),
    products,
    totals
  };
};

const parseTankCapacityLitersFromPayload = (body) => {
  const raw = pickFirst(body || {}, [
    'tank_capacity_liters',
    'tankCapacityLiters',
    'tank_capacity_l',
    'tankCapacityL'
  ]);
  const parsed = toNullableNumber(raw);
  if (parsed == null) return null;
  if (parsed <= 0) return NaN;
  return parsed;
};

const computeWaterLitersFromEnvironment = (environmentRow, tankCapacityLiters = TANK_CAPACITY_L) => {
  const waterLevelPercent = toNullableNumber(environmentRow?.water_level);
  if (waterLevelPercent == null) return null;
  const clampedPercent = clampNumber(waterLevelPercent, 0, 100);
  return (clampedPercent / 100) * tankCapacityLiters;
};

const getDosingConfig = (callback) => {
  db.all(
    `
      SELECT
        product,
        dose_ml_per_l,
        min_ml,
        max_ml,
        min_ml_per_l,
        max_ml_per_l,
        rod_pitch_mm,
        steps_per_turn,
        ml_per_mm
      FROM dosage_config
      ORDER BY product ASC
    `,
    (err, rows) => {
      if (err) return callback(err);

      const configByProduct = {};
      for (const row of rows || []) {
        const product = (row.product || '').toString().trim().toUpperCase();
        if (!DOSING_PRODUCTS.includes(product)) continue;

        const minMlPerL = toNullableNumber(row.min_ml_per_l);
        const maxMlPerL = toNullableNumber(row.max_ml_per_l);
        const minMlLegacyAbs = toNullableNumber(row.min_ml) ?? 0;
        const maxMlLegacyAbs = toNullableNumber(row.max_ml) ?? 0;

        configByProduct[product] = {
          dose_ml_per_l: toNullableNumber(row.dose_ml_per_l) ?? 0,
          min_ml_per_l: minMlPerL,
          max_ml_per_l: maxMlPerL,
          // Legacy absolute values for backward compatibility.
          min_ml: minMlLegacyAbs,
          max_ml: maxMlLegacyAbs,
          rod_pitch_mm: toNullableNumber(row.rod_pitch_mm) ?? 0,
          steps_per_turn: toNullableNumber(row.steps_per_turn) ?? 0,
          ml_per_mm: toNullableNumber(row.ml_per_mm) ?? 0
        };
      }

      return callback(null, configByProduct);
    }
  );
};

const upsertDosingConfig = (configByProduct, callback) => {
  const stmt = db.prepare(
    `
      INSERT INTO dosage_config
      (product, dose_ml_per_l, min_ml, max_ml, min_ml_per_l, max_ml_per_l, rod_pitch_mm, steps_per_turn, ml_per_mm, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
      ON CONFLICT(product) DO UPDATE SET
        dose_ml_per_l = excluded.dose_ml_per_l,
        min_ml = excluded.min_ml,
        max_ml = excluded.max_ml,
        min_ml_per_l = excluded.min_ml_per_l,
        max_ml_per_l = excluded.max_ml_per_l,
        rod_pitch_mm = excluded.rod_pitch_mm,
        steps_per_turn = excluded.steps_per_turn,
        ml_per_mm = excluded.ml_per_mm,
        updated_at = CURRENT_TIMESTAMP
    `
  );

  for (const product of DOSING_PRODUCTS) {
    const config = configByProduct[product];
    const minMlPerL = config.min_ml_per_l;
    const maxMlPerL = config.max_ml_per_l;
    const minMlLegacyAbs = config.min_ml ?? minMlPerL ?? 0;
    const maxMlLegacyAbs = config.max_ml ?? maxMlPerL ?? 0;
    stmt.run([
      product,
      config.dose_ml_per_l,
      minMlLegacyAbs,
      maxMlLegacyAbs,
      minMlPerL,
      maxMlPerL,
      config.rod_pitch_mm,
      config.steps_per_turn,
      config.ml_per_mm
    ]);
  }

  stmt.finalize(callback);
};

const getTankCapacityLiters = (callback) => {
  db.get(
    `
      SELECT setting_value
      FROM app_settings
      WHERE setting_key = 'tank_capacity_liters'
      LIMIT 1
    `,
    (err, row) => {
      if (err) return callback(err);

      const stored = toNullableNumber(row?.setting_value);
      if (stored != null && Number.isFinite(stored) && stored > 0) {
        return callback(null, stored);
      }

      return callback(null, TANK_CAPACITY_L);
    }
  );
};

const upsertTankCapacityLiters = (tankCapacityLiters, callback) => {
  db.run(
    `
      INSERT INTO app_settings (setting_key, setting_value, updated_at)
      VALUES ('tank_capacity_liters', ?, CURRENT_TIMESTAMP)
      ON CONFLICT(setting_key) DO UPDATE SET
        setting_value = excluded.setting_value,
        updated_at = CURRENT_TIMESTAMP
    `,
    [tankCapacityLiters],
    callback
  );
};

const toBoolean = (value) => {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value === 1;
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    if (['1', 'true', 'on', 'marche', 'start'].includes(normalized)) return true;
    if (['0', 'false', 'off', 'arret', 'arrêt', 'stop'].includes(normalized)) return false;
  }
  return false;
};

const parseEvModeOrNull = (value) => {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value === 'boolean') return value ? 'MANUAL' : 'AUTO';
  if (typeof value === 'number') return value === 1 ? 'MANUAL' : 'AUTO';

  const mode = value.toString().trim().toUpperCase();

  if (['MANUAL', 'MANUEL', 'MANUELL', 'ON', 'TRUE', '1'].includes(mode)) return 'MANUAL';
  if (['AUTO', 'AUTOMATIQUE', 'OFF', 'FALSE', '0'].includes(mode)) return 'AUTO';

  return null;
};

const normalizeEvMode = (value) => {
  return parseEvModeOrNull(value) || 'AUTO';
};

const parseOptionalBooleanFlag = (value) => {
  if (value === undefined || value === null || value === '') return null;
  return toBoolean(value) ? 1 : 0;
};

const getZoneUsageFlagsFromAnyShape = (zone) => {
  const nested = zone?.usage || zone?.capteurs || zone?.sensors || {};

  const use_hum = parseOptionalBooleanFlag(
    pickFirst(zone, ['use_hum', 'useHum', 'useHumidity', 'enable_hum', 'hum_enabled'])
    ?? pickFirst(nested, ['use_hum', 'useHum', 'useHumidity', 'enable_hum', 'hum_enabled'])
  );
  const use_temp = parseOptionalBooleanFlag(
    pickFirst(zone, ['use_temp', 'useTemp', 'useTemperature', 'enable_temp', 'temp_enabled'])
    ?? pickFirst(nested, ['use_temp', 'useTemp', 'useTemperature', 'enable_temp', 'temp_enabled'])
  );
  const use_gaz = parseOptionalBooleanFlag(
    pickFirst(zone, ['use_gaz', 'useGaz', 'useGas', 'enable_gaz', 'gaz_enabled'])
    ?? pickFirst(nested, ['use_gaz', 'useGaz', 'useGas', 'enable_gaz', 'gaz_enabled'])
  );
  const use_light = parseOptionalBooleanFlag(
    pickFirst(zone, ['use_light', 'useLight', 'useLux', 'enable_light', 'light_enabled'])
    ?? pickFirst(nested, ['use_light', 'useLight', 'useLux', 'enable_light', 'light_enabled'])
  );
  const use_ev = parseOptionalBooleanFlag(
    pickFirst(zone, ['use_ev', 'useEv', 'useValve', 'enable_ev', 'ev_enabled'])
    ?? pickFirst(nested, ['use_ev', 'useEv', 'useValve', 'enable_ev', 'ev_enabled'])
  );

  return {
    use_hum,
    use_temp,
    use_gaz,
    use_light,
    use_ev
  };
};

const getZoneId = (zone, index) => {
  const zoneId = toNullableNumber(pickFirst(zone, [
    'id', 'zone_id', 'zoneId', 'zone', 'zoneID'
  ]));
  return zoneId ?? (index != null ? index + 1 : null);
};

const getThresholdHumidity = (zone) => toNullableNumber(pickFirst(zone, [
  'thresholdHumidity', 'threshold_humidity', 'humidityThreshold', 'humidity_threshold',
  'hum_threshold', 'humThreshold', 'consigne_hum', 'consigneHum', 'seuil_humidite', 'seuil_hum'
]));

const getThresholdgaz = (zone) => toNullableNumber(pickFirst(zone, [
  'thresholdgaz', 'thresholdGaz', 'threshold_gaz', 'gazThreshold', 'gaz_threshold',
  'gasThreshold', 'thresholdGas', 'thresholdNutrition', 'threshold_nutrition',
  'nutritionThreshold', 'consigne_gaz', 'consignegaz', 'seuil_gaz', 'seuilGaz'
]));

const getThresholdLight = (zone) => toNullableNumber(pickFirst(zone, [
  'thresholdLight', 'threshold_light', 'lightThreshold', 'light_threshold',
  'lux_threshold', 'luxThreshold', 'consigne_light', 'consigneLight', 'seuil_lumiere', 'seuil_light'
]));

const getThresholdTemperature = (zone) => toNullableNumber(pickFirst(zone, [
  'thresholdTemperature', 'threshold_temperature', 'tempThreshold', 'temperatureThreshold',
  'consigne_temp', 'seuil_temp', 'seuil_temperature', 'consigneTemperature', 'seuilTemperature'
]));

const getThresholdsFromAnyShape = (zone) => {
  const nested = zone?.thresholds || zone?.seuils || zone?.setpoints || {};

  let thresholdHumidity = getThresholdHumidity(zone) ?? getThresholdHumidity(nested);
  let thresholdgaz = getThresholdgaz(zone) ?? getThresholdgaz(nested);
  let thresholdLight = getThresholdLight(zone) ?? getThresholdLight(nested);
  let thresholdTemperature = getThresholdTemperature(zone) ?? getThresholdTemperature(nested);

  if (thresholdHumidity == null || thresholdgaz == null || thresholdLight == null || thresholdTemperature == null) {
    const entries = Object.entries({ ...nested, ...zone });

    entries.forEach(([rawKey, rawValue]) => {
      const value = toNullableNumber(rawValue);
      if (value == null) return;

      const key = rawKey.toLowerCase()
        .normalize('NFD')
        .replace(/[^a-z0-9]/g, '');

      if (thresholdHumidity == null && (key.includes('threshold') || key.includes('seuil') || key.includes('consigne')) && (key.includes('hum') || key.includes('humidity'))) {
        thresholdHumidity = value;
        return;
      }

      if (thresholdgaz == null && (key.includes('threshold') || key.includes('seuil') || key.includes('consigne')) && (key.includes('gaz') || key.includes('gaz') || key.includes('ec'))) {
        thresholdgaz = value;
        return;
      }

      if (thresholdLight == null && (key.includes('threshold') || key.includes('seuil') || key.includes('consigne')) && (key.includes('light') || key.includes('lux') || key.includes('lumiere'))) {
        thresholdLight = value;
        return;
      }

      if (thresholdTemperature == null && (key.includes('threshold') || key.includes('seuil') || key.includes('consigne')) && (key.includes('temp') || key.includes('temperature'))) {
        thresholdTemperature = value;
      }
    });
  }

  return {
    thresholdHumidity,
    thresholdgaz,
    thresholdLight,
    thresholdTemperature
  };
};

const getZoneIdFromBody = (body) => {
  const extractZoneId = (value) => {
    if (value === undefined || value === null) return null;

    if (typeof value === 'number' || typeof value === 'string') {
      if (`${value}`.trim() === '') return null;
      return value;
    }

    if (typeof value !== 'object') return null;

    const directPrimitive = pickFirst(value, [
      'id', 'zone_id', 'zoneId', 'zoneID',
      'selected_zone', 'selectedZone', 'zone_number', 'zoneNumber',
      'zone_index', 'zoneIndex', 'target_zone', 'targetZone'
    ]);

    if (typeof directPrimitive === 'number') return directPrimitive;
    if (typeof directPrimitive === 'string' && directPrimitive.trim() !== '') return directPrimitive;

    const nestedCandidates = [
      value.zone,
      value.data,
      value.payload,
      value.zone_to_remove,
      value.remove_zone,
      value.zoneRemove,
      value.zoneToRemove,
      value.selected_zone,
      value.selectedZone,
      value.target_zone,
      value.targetZone
    ].filter((candidate) => candidate !== undefined && candidate !== null);

    for (const candidate of nestedCandidates) {
      const nestedId = extractZoneId(candidate);
      if (nestedId !== null && nestedId !== undefined) {
        return nestedId;
      }
    }

    return null;
  };

  return extractZoneId(body || {});
};

const getZoneNameFromAnyShape = (zone) => pickFirst(zone || {}, [
  'name', 'zone_name', 'zoneName', 'nom', 'label', 'String', 'string'
]);

const sanitizeIncomingZoneName = (rawName) => {
  if (typeof rawName !== 'string') return '';
  return rawName.trim();
};

const normalizeZoneName = (rawName, zoneId) => {
  const trimmed = typeof rawName === 'string' ? rawName.trim() : '';
  if (trimmed) return trimmed;
  return zoneId != null ? `Zone ${zoneId}` : null;
};

const findZoneByName = ({ name, excludeZoneId }, callback) => {
  const trimmedName = typeof name === 'string' ? name.trim() : '';
  if (!trimmedName) return callback(null, null);

  const excludedId = toNullableNumber(excludeZoneId);
  const hasExcludedId = excludedId != null;
  const sql = hasExcludedId
    ? `
      SELECT id, name
      FROM zones
      WHERE LOWER(TRIM(COALESCE(name, ''))) = LOWER(TRIM(?))
        AND id <> ?
      LIMIT 1
    `
    : `
      SELECT id, name
      FROM zones
      WHERE LOWER(TRIM(COALESCE(name, ''))) = LOWER(TRIM(?))
      LIMIT 1
    `;
  const params = hasExcludedId ? [trimmedName, excludedId] : [trimmedName];

  db.get(sql, params, (err, row) => {
    if (err) return callback(err);
    return callback(null, row || null);
  });
};

const rawMobileNameGuardMs = Number.parseInt(process.env.MOBILE_NAME_GUARD_MS || '30000', 10);
const MOBILE_NAME_GUARD_MS = Number.isInteger(rawMobileNameGuardMs) && rawMobileNameGuardMs > 0
  ? rawMobileNameGuardMs
  : 30000;
const mobileNameGuards = new Map();

const setMobileNameGuard = (zoneIdRaw, nameRaw) => {
  const zoneId = toNullableNumber(zoneIdRaw);
  const name = normalizeZoneName(nameRaw, zoneId);
  if (zoneId == null || !name) return;
  mobileNameGuards.set(zoneId, {
    name,
    expiresAt: Date.now() + MOBILE_NAME_GUARD_MS
  });
};

const applyZoneNameGuard = (zoneIdRaw, incomingNameRaw) => {
  const zoneId = toNullableNumber(zoneIdRaw);
  const incomingName = typeof incomingNameRaw === 'string' ? incomingNameRaw.trim() : '';
  if (zoneId == null) return incomingName;

  const guard = mobileNameGuards.get(zoneId);
  if (!guard) return incomingName;

  if (Date.now() > guard.expiresAt) {
    mobileNameGuards.delete(zoneId);
    return incomingName;
  }

  // Guard active: avoid immediate stale rename rollback from delayed LabVIEW payloads.
  if (!incomingName) return guard.name;
  if (incomingName.toLowerCase() === guard.name.toLowerCase()) {
    mobileNameGuards.delete(zoneId);
    return incomingName;
  }
  return guard.name;
};

const normalizeZoneConfig = (zoneRow) => ({
  id: toNullableNumber(zoneRow?.id),
  name: zoneRow?.name || normalizeZoneName(null, toNullableNumber(zoneRow?.id)) || '',
  seuil_light: toNullableNumber(zoneRow?.thresholdLight) ?? 200,
  seuil_hum: toNullableNumber(zoneRow?.thresholdHumidity) ?? 30,
  seuil_gaz: toNullableNumber(zoneRow?.thresholdgaz) ?? 50,
  seuil_temp: toNullableNumber(zoneRow?.thresholdTemperature) ?? 25,
  ev_mode: (zoneRow?.ev_mode || 'AUTO').toString().toUpperCase() === 'MANUAL',
  use_hum: (toNullableNumber(zoneRow?.use_hum) ?? 1) === 1,
  use_temp: (toNullableNumber(zoneRow?.use_temp) ?? 1) === 1,
  use_gaz: (toNullableNumber(zoneRow?.use_gaz) ?? 1) === 1,
  use_light: (toNullableNumber(zoneRow?.use_light) ?? 1) === 1,
  use_ev: (toNullableNumber(zoneRow?.use_ev) ?? 1) === 1
});

const parseJsonArray = (rawValue) => {
  if (!rawValue) return [];
  try {
    const parsed = JSON.parse(rawValue);
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    return [];
  }
};

const collectZoneIds = (items) => {
  if (!Array.isArray(items)) return [];

  const ids = [];
  items.forEach((item, index) => {
    const zoneId = getZoneId(item, index);
    if (zoneId == null) return;
    const normalized = Math.trunc(Number(zoneId));
    if (!Number.isFinite(normalized) || normalized <= 0) return;
    ids.push(normalized);
  });

  return [...new Set(ids)];
};

const buildLabviewAlertsFromData = (data) => {
  const alerts = [];

  const pushAlert = (zoneIdRaw, zoneNameRaw, messageRaw, levelRaw = 'WARNING') => {
    const zone_id = toNullableNumber(zoneIdRaw);
    const zone_name = (zoneNameRaw || '').toString().trim();
    const message = (messageRaw || '').toString().trim();
    const level = (levelRaw || 'WARNING').toString().trim().toUpperCase();

    if (!message) return;

    alerts.push({
      zone_id,
      zone_name,
      message,
      level
    });
  };

  const runtimeList = Array.isArray(data?.zone_runtime) ? data.zone_runtime : [];

  runtimeList.forEach((runtime, index) => {
    const zoneId = getZoneId(runtime, index);
    const zoneName = getZoneNameFromAnyShape(runtime);

    // Cas 1: message d'erreur explicite envoyé par LabVIEW
    const directMessage = pickFirst(runtime, [
      'error_message', 'errorMessage', 'message', 'msg', 'alerte', 'alert', 'error', 'erreur'
    ]);

    const directLevel = pickFirst(runtime, ['level', 'severity', 'type', 'niveau']);
    if (directMessage != null && `${directMessage}`.trim() !== '') {
      pushAlert(zoneId, zoneName, directMessage, directLevel || 'ERROR');
    }
  });

  // Cas 2: tableau global d'alertes dans le payload /labview/data
  const globalAlerts = Array.isArray(data?.alerts)
    ? data.alerts
    : Array.isArray(data?.zone_alerts)
      ? data.zone_alerts
      : [];

  globalAlerts.forEach((entry, index) => {
    const zoneId = getZoneId(entry, index);
    const zoneName = getZoneNameFromAnyShape(entry);
    const message = pickFirst(entry, [
      'error_message', 'errorMessage', 'message', 'msg', 'alerte', 'alert', 'error', 'erreur', 'text'
    ]);
    const level = pickFirst(entry, ['level', 'severity', 'type', 'niveau']);
    pushAlert(zoneId, zoneName, message, level || 'ERROR');
  });

  return alerts;
};

const formatLabviewCommand = (cmd, zoneRow, allZoneRows) => {
  if (!cmd) {
    return {
      zone_config: [],
      zone_runtime: []
    };
  }

  const oldZoneConfig = parseJsonArray(cmd.old_zone_config);
  const newZoneConfig = parseJsonArray(cmd.new_zone_config);

  if (oldZoneConfig.length || newZoneConfig.length) {
    return {
      zone_config: newZoneConfig.length ? newZoneConfig : oldZoneConfig,
      zone_runtime: []
    };
  }

  const allConfigs = (allZoneRows || []).map(normalizeZoneConfig);
  const fallbackConfig = normalizeZoneConfig({ ...zoneRow, id: cmd.zone });
  const zoneConfig = allConfigs.length ? allConfigs : [fallbackConfig];
  const cmdValveNumber = toNullableNumber(cmd.valve);
  const currentZoneValve = (toNullableNumber(zoneRow?.valve) ?? 0) === 1;
  const evState = cmdValveNumber == null ? currentZoneValve : cmdValveNumber === 1;
  const mode = normalizeEvMode(cmd.mode || 'AUTO');
  const evModeBool = mode === 'MANUAL';
  const labviewMode = mode === 'MANUAL' ? 'manuel' : 'auto';

  // Build zone_runtime for ALL zones
  const zone_runtime = (allZoneRows || []).map((zone) => {
    const zoneId = toNullableNumber(zone.id);
    const isCommandZone = zoneId === toNullableNumber(cmd.zone);
    
    return {
      id: zoneId,
      zone_id: zoneId,
      ev_state: isCommandZone ? evState : ((toNullableNumber(zone.valve) ?? 0) === 1),
      ev_mode: isCommandZone
        ? evModeBool
        : (normalizeEvMode(zone.ev_mode || 'AUTO') === 'MANUAL'),
      alert_light: false,
      alert_gaz: false,
      alert_hum: false,
      alert_temp: false,
      mode: isCommandZone ? labviewMode : (normalizeEvMode(zone.ev_mode || 'AUTO') === 'MANUAL' ? 'manuel' : 'auto')
    };
  });

  return {
    zone_config: zoneConfig,
    zone_runtime: zone_runtime.length ? zone_runtime : [{
      id: toNullableNumber(cmd.zone),
      zone_id: toNullableNumber(cmd.zone),
      ev_state: evState,
      ev_mode: evModeBool,
      alert_light: false,
      alert_gaz: false,
      alert_hum: false,
      alert_temp: false,
      mode: labviewMode
    }]
  };
};
// =======================
// CREATION DES TABLES
// =======================

db.serialize(() => {
  // ENVIRONNEMENT (historique)
  db.run(`
  CREATE TABLE IF NOT EXISTS environment (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    temperature REAL,
    humidity_air REAL,
    water_level REAL,
    water_ph REAL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
  `);

  db.all(`PRAGMA table_info(environment)`, (schemaErr, columns) => {
    if (schemaErr) return;

    const names = new Set((columns || []).map((column) => column.name));
    if (!names.has('water_ph')) {
      db.run(`ALTER TABLE environment ADD COLUMN water_ph REAL`);
    }
  });

  // ETAT ACTUEL DES ZONES
  db.run(`
  CREATE TABLE IF NOT EXISTS zones (
    id INTEGER PRIMARY KEY,
    name TEXT,
    humidity REAL,
    temperature REAL,
    gaz REAL,
    light REAL,
    thresholdHumidity REAL,
    thresholdgaz REAL,
    thresholdLight REAL,
    thresholdTemperature REAL,
    valve INTEGER,
    ev_mode TEXT DEFAULT 'AUTO',
    use_hum INTEGER DEFAULT 1,
    use_temp INTEGER DEFAULT 1,
    use_gaz INTEGER DEFAULT 1,
    use_light INTEGER DEFAULT 1,
    use_ev INTEGER DEFAULT 1
  )
  `);

  db.all(`PRAGMA table_info(zones)`, (schemaErr, columns) => {
    if (schemaErr) return;

    const names = new Set((columns || []).map((column) => column.name));
    const hasLegacyNutrition = names.has('nutrition');
    const hasLegacyThresholdNutrition = names.has('thresholdNutrition');

    if (!names.has('name')) {
      db.run(`ALTER TABLE zones ADD COLUMN name TEXT`);
    }

    if (!names.has('ev_mode')) {
      db.run(`ALTER TABLE zones ADD COLUMN ev_mode TEXT DEFAULT 'AUTO'`);
    }

    if (!names.has('temperature')) {
      db.run(`ALTER TABLE zones ADD COLUMN temperature REAL`);
    }

    if (!names.has('gaz')) {
      db.run(`ALTER TABLE zones ADD COLUMN gaz REAL`);
    }

    if (!names.has('thresholdgaz')) {
      db.run(`ALTER TABLE zones ADD COLUMN thresholdgaz REAL`);
    }
    if (!names.has('thresholdTemperature')) {
      db.run(`ALTER TABLE zones ADD COLUMN thresholdTemperature REAL`);
    }

    if (!names.has('use_hum')) {
      db.run(`ALTER TABLE zones ADD COLUMN use_hum INTEGER DEFAULT 1`);
    }

    if (!names.has('use_temp')) {
      db.run(`ALTER TABLE zones ADD COLUMN use_temp INTEGER DEFAULT 1`);
    }

    if (!names.has('use_gaz')) {
      db.run(`ALTER TABLE zones ADD COLUMN use_gaz INTEGER DEFAULT 1`);
    }

    if (!names.has('use_light')) {
      db.run(`ALTER TABLE zones ADD COLUMN use_light INTEGER DEFAULT 1`);
    }

    if (!names.has('use_ev')) {
      db.run(`ALTER TABLE zones ADD COLUMN use_ev INTEGER DEFAULT 1`);
    }

    // Normaliser les anciennes lignes (éviter les NULL côté Flutter)
    const legacyGazExpr = hasLegacyNutrition ? 'COALESCE(gaz, nutrition, 0)' : 'COALESCE(gaz, 0)';
    const legacyThresholdGazExpr = hasLegacyThresholdNutrition
      ? 'COALESCE(thresholdgaz, thresholdNutrition, 50)'
      : 'COALESCE(thresholdgaz, 50)';

    const normalizeZonesSqlWithUsage = `
      UPDATE zones
      SET
        name = COALESCE(NULLIF(TRIM(name), ''), 'Zone ' || id),
        temperature = COALESCE(temperature, 0),
        gaz = ${legacyGazExpr},
        thresholdHumidity = COALESCE(thresholdHumidity, 30),
        thresholdgaz = ${legacyThresholdGazExpr},
        thresholdLight = COALESCE(thresholdLight, 200),
        thresholdTemperature = COALESCE(thresholdTemperature, 25),
        valve = COALESCE(valve, 0),
        use_hum = CASE WHEN COALESCE(use_hum, 1) = 1 THEN 1 ELSE 0 END,
        use_temp = CASE WHEN COALESCE(use_temp, 1) = 1 THEN 1 ELSE 0 END,
        use_gaz = CASE WHEN COALESCE(use_gaz, 1) = 1 THEN 1 ELSE 0 END,
        use_light = CASE WHEN COALESCE(use_light, 1) = 1 THEN 1 ELSE 0 END,
        use_ev = CASE WHEN COALESCE(use_ev, 1) = 1 THEN 1 ELSE 0 END,
        ev_mode = CASE
          WHEN UPPER(COALESCE(TRIM(ev_mode), '')) = 'MANUAL' THEN 'MANUAL'
          ELSE 'AUTO'
        END
    `;

    const normalizeZonesSqlLegacy = `
      UPDATE zones
      SET
        name = COALESCE(NULLIF(TRIM(name), ''), 'Zone ' || id),
        temperature = COALESCE(temperature, 0),
        gaz = ${legacyGazExpr},
        thresholdHumidity = COALESCE(thresholdHumidity, 30),
        thresholdgaz = ${legacyThresholdGazExpr},
        thresholdLight = COALESCE(thresholdLight, 200),
        thresholdTemperature = COALESCE(thresholdTemperature, 25),
        valve = COALESCE(valve, 0),
        ev_mode = CASE
          WHEN UPPER(COALESCE(TRIM(ev_mode), '')) = 'MANUAL' THEN 'MANUAL'
          ELSE 'AUTO'
        END
    `;

    db.run(normalizeZonesSqlWithUsage, (normalizeErr) => {
      if (!normalizeErr) return;

      if (normalizeErr.code === 'SQLITE_ERROR' && /no such column/i.test(normalizeErr.message || '')) {
        db.run(normalizeZonesSqlLegacy);
      }
    });
  });

  // HISTORIQUE ZONES
  db.run(`
  CREATE TABLE IF NOT EXISTS zones_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    zone_id INTEGER,
    humidity REAL,
    temperature REAL,
    gaz REAL,
    light REAL,
    valve INTEGER,
    ev_mode TEXT DEFAULT 'AUTO',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
  `);

  // HISTORIQUE PERIODIQUE (snapshot toutes les zones)
  db.run(`
  CREATE TABLE IF NOT EXISTS zones_periodic_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    snapshot_batch_id TEXT,
    zone_id INTEGER,
    humidity REAL,
    temperature REAL,
    gaz REAL,
    light REAL,
    valve INTEGER,
    ev_mode TEXT DEFAULT 'AUTO',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
  `);

  db.all(`PRAGMA table_info(zones_history)`, (schemaErr, columns) => {
    if (schemaErr) return;
    const names = new Set((columns || []).map((column) => column.name));
    const hasLegacyNutrition = names.has('nutrition');

    const normalizeExistingRows = () => {
      const legacyGazExpr = hasLegacyNutrition ? 'COALESCE(gaz, nutrition, 0)' : 'COALESCE(gaz, 0)';
      db.run(`
        UPDATE zones_history
        SET
          ev_mode = COALESCE(NULLIF(TRIM(ev_mode), ''), 'AUTO'),
          temperature = COALESCE(temperature, 0),
          gaz = ${legacyGazExpr}
      `);
    };

    if (!names.has('gaz')) {
      db.run(
        `ALTER TABLE zones_history ADD COLUMN gaz REAL`,
        (alterErr) => {
          if (alterErr) return;
          normalizeExistingRows();
        }
      );
      return;
    }

    if (!names.has('temperature')) {
      db.run(
        `ALTER TABLE zones_history ADD COLUMN temperature REAL`,
        (alterErr) => {
          if (alterErr) return;
          normalizeExistingRows();
        }
      );
      return;
    }

    if (!names.has('ev_mode')) {
      db.run(
        `ALTER TABLE zones_history ADD COLUMN ev_mode TEXT DEFAULT 'AUTO'`,
        (alterErr) => {
          if (alterErr) return;
          normalizeExistingRows();
        }
      );
      return;
    }

    normalizeExistingRows();
  });

  db.all(`PRAGMA table_info(zones_periodic_history)`, (schemaErr, columns) => {
    if (schemaErr) return;
    const names = new Set((columns || []).map((column) => column.name));
    const hasLegacyNutrition = names.has('nutrition');

    const normalizePeriodicRows = () => {
      const legacyGazExpr = hasLegacyNutrition ? 'COALESCE(gaz, nutrition, 0)' : 'COALESCE(gaz, 0)';
      db.run(`
        UPDATE zones_periodic_history
        SET
          temperature = COALESCE(temperature, 0),
          gaz = ${legacyGazExpr}
      `);
    };

    if (!names.has('gaz')) {
      db.run(`ALTER TABLE zones_periodic_history ADD COLUMN gaz REAL`, (alterErr) => {
        if (alterErr) return;
        normalizePeriodicRows();
      });
      return;
    }

    if (!names.has('temperature')) {
      db.run(`ALTER TABLE zones_periodic_history ADD COLUMN temperature REAL`, (alterErr) => {
        if (alterErr) return;
        normalizePeriodicRows();
      });
      return;
    }

    normalizePeriodicRows();
  });

  // COMMANDES
  db.run(`
  CREATE TABLE IF NOT EXISTS commands (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    zone INTEGER,
    valve INTEGER,
    mode TEXT,
    status TEXT DEFAULT 'NEW',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
  `, () => {
    db.all(`PRAGMA table_info(commands)`, (schemaErr, columns) => {
      if (schemaErr) return;

      const names = new Set((columns || []).map((column) => column.name));

      if (!names.has('old_zone_config')) {
        db.run(`ALTER TABLE commands ADD COLUMN old_zone_config TEXT`);
      }

      if (!names.has('new_zone_config')) {
        db.run(`ALTER TABLE commands ADD COLUMN new_zone_config TEXT`);
      }

      if (!names.has('event_type')) {
        db.run(`ALTER TABLE commands ADD COLUMN event_type TEXT`);
      }

      if (!names.has('alert_message')) {
        db.run(`ALTER TABLE commands ADD COLUMN alert_message TEXT`);
      }

      if (!names.has('alert_level')) {
        db.run(`ALTER TABLE commands ADD COLUMN alert_level TEXT`);
      }

      if (!names.has('alert_source')) {
        db.run(`ALTER TABLE commands ADD COLUMN alert_source TEXT`);
      }

      if (!names.has('alert_created_at')) {
        db.run(`ALTER TABLE commands ADD COLUMN alert_created_at DATETIME`);
      }
    });
  });

  db.run(`
  CREATE INDEX IF NOT EXISTS idx_env_date
  ON environment(created_at)
  `);

  db.run(`
  CREATE INDEX IF NOT EXISTS idx_zones_history_date
  ON zones_history(created_at)
  `);

  db.run(`
  CREATE INDEX IF NOT EXISTS idx_zones_history_zone_date
  ON zones_history(zone_id, created_at)
  `);

  db.run(`
  CREATE INDEX IF NOT EXISTS idx_zones_periodic_history_date
  ON zones_periodic_history(created_at)
  `);

  db.run(`
  CREATE INDEX IF NOT EXISTS idx_zones_periodic_history_batch
  ON zones_periodic_history(snapshot_batch_id)
  `);

  db.run(`
  CREATE INDEX IF NOT EXISTS idx_zones_periodic_history_zone_date
  ON zones_periodic_history(zone_id, created_at)
  `);

  db.run(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT UNIQUE,
    password TEXT,
    role TEXT DEFAULT 'user',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
  `);

  db.run(`
  CREATE TABLE IF NOT EXISTS dosage_config (
    product TEXT PRIMARY KEY,
    dose_ml_per_l REAL NOT NULL DEFAULT 0,
    min_ml REAL NOT NULL DEFAULT 0,
    max_ml REAL NOT NULL DEFAULT 0,
    min_ml_per_l REAL,
    max_ml_per_l REAL,
    rod_pitch_mm REAL NOT NULL DEFAULT 0,
    steps_per_turn REAL NOT NULL DEFAULT 0,
    ml_per_mm REAL NOT NULL DEFAULT 0,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
  `);

  // Backward-compatible migration: older DBs may not have per-liter bound columns.
  db.run(`ALTER TABLE dosage_config ADD COLUMN min_ml_per_l REAL`, () => {});
  db.run(`ALTER TABLE dosage_config ADD COLUMN max_ml_per_l REAL`, () => {});

  db.run(`
  CREATE TABLE IF NOT EXISTS app_settings (
    setting_key TEXT PRIMARY KEY,
    setting_value TEXT NOT NULL,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
  `);
});

const insertPeriodicSnapshotNow = (reason = 'TIMER') => {
  db.all(
    `SELECT id, humidity, temperature, gaz, light, valve, ev_mode FROM zones ORDER BY id ASC`,
    (zonesErr, zones) => {
      if (zonesErr) {
        console.error('periodic snapshot zones read error:', zonesErr.message);
        return;
      }

      const rows = zones || [];
      if (!rows.length) return;

      const batchId = generateSnapshotBatchId();
      const stmt = db.prepare(`
        INSERT INTO zones_periodic_history
        (snapshot_batch_id, zone_id, humidity, temperature, gaz, light, valve, ev_mode)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      `);

      rows.forEach((z) => {
        stmt.run([
          batchId,
          toNullableNumber(z.id),
          toNullableNumber(z.humidity) ?? 0,
          toNullableNumber(z.temperature) ?? 0,
          toNullableNumber(z.gaz) ?? 0,
          toNullableNumber(z.light) ?? 0,
          (toNullableNumber(z.valve) ?? 0) === 1 ? 1 : 0,
          normalizeEvMode(z.ev_mode || 'AUTO')
        ]);
      });

      stmt.finalize((finalErr) => {
        if (finalErr) {
          console.error('periodic snapshot insert error:', finalErr.message);
          return;
        }

        if (reason !== 'TIMER') {
          console.log(`Periodic snapshot inserted (${reason}) batch=${batchId} zones=${rows.length}`);
        }
      });
    }
  );
};

const PERIODIC_SNAPSHOT_INTERVAL_MS = 60 * 1000;

// Keep periodic history filled for "valeurs capteurs" mode.
setInterval(() => {
  insertPeriodicSnapshotNow('TIMER');
}, PERIODIC_SNAPSHOT_INTERVAL_MS);

// Warmup snapshot shortly after startup so history is not empty.
setTimeout(() => {
  insertPeriodicSnapshotNow('BOOT');
}, 5000);

// Créer la table des alertes zones
db.run(`
  CREATE TABLE IF NOT EXISTS zone_alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    zone_id INTEGER,
    zone_name TEXT,
    message TEXT,
    level TEXT DEFAULT 'WARNING',
    source TEXT DEFAULT 'LABVIEW',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
`);

db.run(`
  CREATE INDEX IF NOT EXISTS idx_zone_alerts_zone_date
  ON zone_alerts(zone_id, created_at)
`);

db.run(`
  CREATE TABLE IF NOT EXISTS zone_active_alerts (
    zone_id INTEGER PRIMARY KEY,
    message TEXT,
    level TEXT DEFAULT 'WARNING',
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
`);

// Supprimer les alertes synthétiques générées par erreur
db.run(`
  DELETE FROM zone_alerts
  WHERE message IN ('Alerte lumiere zone', 'Alerte gaz zone', 'Alerte humidite zone')
`);

// Seed du compte principal via variables d'environnement.
if (DEFAULT_USER_PASSWORD) {
  bcrypt.hash(DEFAULT_USER_PASSWORD, AUTH_BCRYPT_ROUNDS).then((hash) => {
    db.run(
      `INSERT OR IGNORE INTO users (email, password, role) VALUES (?, ?, 'user')`,
      [DEFAULT_USER_EMAIL, hash]
    );
  }).catch((err) => {
    console.error('Default user seed error:', err.message);
  });
} else {
  console.warn('SINGLE_USER_PASSWORD is empty. No default user has been seeded.');
}

// =======================
// ROUTE TEST
// =======================

app.get('/', (req, res) => {
  res.json({ message: " Advanced IoT Server Running" });
});

app.get('/health', (req, res) => {
  res.status(200).json({ ok: true });
});
// =======================
// AUTH REGISTER
// =======================

app.post('/register', async (req, res) => {

  if (!ALLOW_REGISTER) {
    return res.status(403).json({ error: 'Registration is disabled' });
  }

  const { email, password } = req.body;
  const normalizedEmail = normalizeEmail(email);
  const normalizedPassword = (password || '').toString();

  if(!normalizedEmail || !normalizedPassword){
    return res.status(400).json({error:"Missing fields"});
  }

  if (!EMAIL_REGEX.test(normalizedEmail)) {
    return res.status(400).json({ error: 'Invalid email format' });
  }

  if (normalizedPassword.length < 10) {
    return res.status(400).json({ error: 'Password must be at least 10 characters' });
  }

  const hashedPassword = await bcrypt.hash(normalizedPassword, AUTH_BCRYPT_ROUNDS);

  db.run(`
    INSERT INTO users (email, password)
    VALUES (?, ?)
  `,
  [normalizedEmail, hashedPassword],
  function(err){

    if(err){
      return res.status(500).json({error:"User exists"});
    }

    res.json({status:"User created"});
  });

});
// =======================
// AUTH LOGIN
// =======================

app.get('/login', (_req, res) => {
  res.status(405).json({ error: 'Use POST /login with email and password' });
});

app.post('/login', (req,res)=>{

  const { email, password } = req.body;
  const normalizedEmail = normalizeEmail(email);
  const normalizedPassword = (password || '').toString();
  const ip = getClientIp(req);

  if (isLoginBlocked(ip)) {
    return res.status(429).json({ error: 'Too many failed attempts. Try again later.' });
  }

  if (!normalizedEmail || !normalizedPassword) {
    return res.status(400).json({ error: 'email and password are required' });
  }

  db.get(`
    SELECT * FROM users WHERE email = ?
  `,
  [normalizedEmail],
  async (err,user)=>{

    if (err) {
      return res.status(500).json({ error: err.message });
    }

    if(!user){
      registerLoginFailure(ip);
      return res.status(401).json({error:"Invalid credentials"});
    }

    const valid = await bcrypt.compare(normalizedPassword, user.password);

    if(!valid){
      registerLoginFailure(ip);
      return res.status(401).json({error:"Invalid credentials"});
    }

    clearLoginFailures(ip);

    const jwtExpiresIn = process.env.JWT_EXPIRES_IN || '7d';

    const token = jwt.sign(
      { id:user.id, email:user.email },
      SECRET_KEY,
      { expiresIn: jwtExpiresIn }
    );

    res.json({
      token:token,
      email:user.email
    });

  });

});
// =======================
// LABVIEW → ENVIRONNEMENT
// =======================

app.post('/update-environment', (req, res) => {

  const temperature = toNullableNumber(pickFirst(req.body || {}, ['temperature', 'temp_en', 'temp']));
  const humidity_air = toNullableNumber(pickFirst(req.body || {}, ['humidity_air', 'hum_en', 'humidity']));
  const water_level = toNullableNumber(pickFirst(req.body || {}, ['water_level', 'waterLevel', 'eau']));
  const water_ph = toNullableNumber(pickFirst(req.body || {}, [
    'water_ph', 'waterPh', 'ph_water', 'phWater', 'ph_eau', 'eau_ph', 'ph'
  ]));

  db.run(`
    INSERT INTO environment (temperature, humidity_air, water_level, water_ph)
    VALUES (?, ?, ?, ?)
  `, [temperature, humidity_air, water_level, water_ph], function(err) {

    if (err) {
      return res.status(500).json({ error: err.message });
    }

    //  TEMPS RÉEL POUR DASHBOARD
    io.emit("environment-update", {
      temperature,
      humidity_air,
      water_level,
      water_ph
    });

    emitHistoryRealtime();

    res.json({ status: "Environment updated" });

  });
});

// =======================
// LABVIEW → ZONES
// =======================

app.post('/update-zones', (req, res) => {

  const zones =
    Array.isArray(req.body) ? req.body :
    Array.isArray(req.body?.zones) ? req.body.zones :
    Array.isArray(req.body?.zone_measure) ? req.body.zone_measure : [];

  if (!zones.length) {
    return res.status(400).json({ error: "Invalid payload: zones[] is required" });
  }

  db.serialize(() => {
    zones.forEach((zone, index) => {

      const zoneId = getZoneId(zone, index);
      if (!zoneId) return;

      const humidity = toNullableNumber(pickFirst(zone, ['humidity', 'hum', 'h']));
      const temperature = toNullableNumber(pickFirst(zone, ['temperature', 'temp', 't']));
      const gaz = toNullableNumber(pickFirst(zone, ['gaz', 'nutrition', 'gas', 'n']));
      const light = toNullableNumber(pickFirst(zone, ['light', 'lux', 'l']));
      const zoneName = applyZoneNameGuard(
        zoneId,
        sanitizeIncomingZoneName(getZoneNameFromAnyShape(zone))
      );

      const {
        thresholdHumidity,
        thresholdgaz,
        thresholdLight,
        thresholdTemperature
      } = getThresholdsFromAnyShape(zone);
      const {
        use_hum,
        use_temp,
        use_gaz,
        use_light,
        use_ev
      } = getZoneUsageFlagsFromAnyShape(zone);

      const rawValve = pickFirst(zone, ['valve', 'ev_state', 'electrovalve', 'electroValve']);
      const valve = rawValve == null ? null : ((rawValve === true || rawValve === 1 || rawValve === '1') ? 1 : 0);
      const evMode = parseEvModeOrNull(pickFirst(zone, ['mode', 'ev_mode', 'mode_ev']));

      // 🔹 Mise à jour état actuel (sans écraser les seuils existants par NULL)
      db.run(`
        INSERT INTO zones
        (id, name, humidity, temperature, gaz, light,
         thresholdHumidity, thresholdgaz,
         thresholdLight, thresholdTemperature, valve, ev_mode,
         use_hum, use_temp, use_gaz, use_light, use_ev)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          name = CASE
            WHEN NULLIF(TRIM(excluded.name), '') IS NULL THEN COALESCE(zones.name, 'Zone ' || zones.id)
            WHEN EXISTS (
              SELECT 1
              FROM zones z2
              WHERE z2.id <> zones.id
                AND LOWER(TRIM(COALESCE(z2.name, ''))) = LOWER(TRIM(excluded.name))
            ) THEN COALESCE(zones.name, 'Zone ' || zones.id)
            ELSE TRIM(excluded.name)
          END,
          humidity = COALESCE(excluded.humidity, zones.humidity),
          temperature = COALESCE(excluded.temperature, zones.temperature),
          gaz = COALESCE(excluded.gaz, zones.gaz),
          light = COALESCE(excluded.light, zones.light),
          thresholdHumidity = COALESCE(excluded.thresholdHumidity, zones.thresholdHumidity, 30),
          thresholdgaz = COALESCE(excluded.thresholdgaz, zones.thresholdgaz, 50),
          thresholdLight = COALESCE(excluded.thresholdLight, zones.thresholdLight, 200),
          thresholdTemperature = COALESCE(excluded.thresholdTemperature, zones.thresholdTemperature, 25),
          valve = COALESCE(excluded.valve, zones.valve, 0),
          ev_mode = COALESCE(excluded.ev_mode, zones.ev_mode, 'AUTO'),
          use_hum = COALESCE(excluded.use_hum, zones.use_hum, 1),
          use_temp = COALESCE(excluded.use_temp, zones.use_temp, 1),
          use_gaz = COALESCE(excluded.use_gaz, zones.use_gaz, 1),
          use_light = COALESCE(excluded.use_light, zones.use_light, 1),
          use_ev = COALESCE(excluded.use_ev, zones.use_ev, 1)
      `,
      [
        zoneId,
        zoneName,
        humidity,
        temperature,
        gaz,
        light,
        thresholdHumidity,
        thresholdgaz,
        thresholdLight,
        thresholdTemperature,
        valve,
        evMode,
        use_hum,
        use_temp,
        use_gaz,
        use_light,
        use_ev
      ]);

      // 🔹 Historique
      db.run(`
        INSERT INTO zones_history
        (zone_id, humidity, temperature, gaz, light, valve, ev_mode)
        SELECT
          z.id,
          z.humidity,
          z.temperature,
          z.gaz,
          z.light,
          COALESCE(z.valve, 0),
          COALESCE(z.ev_mode, 'AUTO')
        FROM zones z
        WHERE z.id = ?
          AND NOT EXISTS (
            SELECT 1
            FROM (
              SELECT humidity, temperature, gaz, light, valve, ev_mode
              FROM zones_history
              WHERE zone_id = z.id
              ORDER BY created_at DESC, id DESC
              LIMIT 1
            ) last
            WHERE COALESCE(last.humidity, -999999) = COALESCE(z.humidity, -999999)
              AND COALESCE(last.temperature, -999999) = COALESCE(z.temperature, -999999)
              AND COALESCE(last.gaz, -999999) = COALESCE(z.gaz, -999999)
              AND COALESCE(last.light, -999999) = COALESCE(z.light, -999999)
              AND COALESCE(last.valve, -999999) = COALESCE(COALESCE(z.valve, 0), -999999)
              AND COALESCE(last.ev_mode, '') = COALESCE(z.ev_mode, '')
          )
      `, [zoneId]);

    });

    //  TEMPS RÉEL (après écritures DB)
    db.all(`SELECT * FROM zones`, (err, freshZones) => {
      if (err) return res.status(500).json({ error: err.message });
      io.emit("zones-update", freshZones || []);
      emitZoneConfigUpdate();
      emitHistoryRealtime();
      res.json({ status: "Zones updated with history" });
    });

  });

});
// =======================
// LABVIEW → DATA COMPLETE
// =======================

app.post('/labview/data', (req, res) => {
  console.log("DATA FROM LABVIEW:");
  console.log(req.body);
  const data = req.body;

  // ---------- ENVIRONNEMENT ----------
  if(data.g_env){
    const envTemperature = toNullableNumber(pickFirst(data.g_env || {}, ['temp_en', 'temperature', 'temp']));
    const envHumidityAir = toNullableNumber(pickFirst(data.g_env || {}, ['hum_en', 'humidity_air', 'humidity']));
    const envWaterLevel = toNullableNumber(pickFirst(data.g_env || {}, ['eau', 'water_level', 'waterLevel']));
    const envWaterPh = toNullableNumber(pickFirst(data.g_env || {}, [
      'water_ph', 'waterPh', 'ph_water', 'phWater', 'ph_eau', 'eau_ph', 'ph_en', 'ph'
    ]));

    db.run(`
      INSERT INTO environment (temperature, humidity_air, water_level, water_ph)
      VALUES (?, ?, ?, ?)
    `,
    [
      envTemperature,
      envHumidityAir,
      envWaterLevel,
      envWaterPh
    ]);

    io.emit("environment-update", {
      temperature: envTemperature,
      humidity_air: envHumidityAir,
      water_level: envWaterLevel,
      water_ph: envWaterPh
    });

  }

  db.serialize(() => {
    let oldZoneConfigForLabviewDiff = [];
    getAllZoneConfigs((snapshotErr, snapshot) => {
      if (snapshotErr) return;
      oldZoneConfigForLabviewDiff = snapshot || [];
    });

    const pickZoneIdsForAlertsOut = () => {
      const idsFromRuntime = collectZoneIds(data?.zone_runtime);
      if (idsFromRuntime.length) return idsFromRuntime;

      const idsFromConfig = collectZoneIds(data?.zone_config);
      if (idsFromConfig.length) return idsFromConfig;

      const idsFromMeasure = collectZoneIds(data?.zone_measure);
      if (idsFromMeasure.length) return idsFromMeasure;

      return [];
    };

    const incomingAlerts = buildLabviewAlertsFromData(data);

    if (incomingAlerts.length) {
      const stmt = db.prepare(`
        INSERT INTO zone_alerts (zone_id, zone_name, message, level, source)
        VALUES (?, ?, ?, ?, 'LABVIEW')
      `);
      const stmtUpsertActiveAlert = db.prepare(`
        INSERT INTO zone_active_alerts (zone_id, message, level, updated_at)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(zone_id) DO UPDATE SET
          message = excluded.message,
          level = excluded.level,
          updated_at = CURRENT_TIMESTAMP
      `);

      incomingAlerts.forEach((alert) => {
        stmt.run([
          alert.zone_id,
          alert.zone_name,
          alert.message,
          alert.level
        ]);

        stmtUpsertActiveAlert.run([
          alert.zone_id,
          alert.message,
          alert.level
        ]);
      });

      stmt.finalize(() => {
        stmtUpsertActiveAlert.finalize();

        const filtered = filterUniqueAlertChanges(
          incomingAlerts.map((alert) => ({
            ...alert,
            source: alert.source || 'LABVIEW',
            level: alert.level || 'WARNING'
          }))
        );

        if (filtered.length > 0) {
          io.emit("zone-alert", filtered);
          emitHistoryRealtime();
        }
      });

}  

    if (Array.isArray(data?.alerts_out)) {
      const alertsOut = data.alerts_out.map((msg) => (msg ?? '').toString().trim());
      const payloadZoneIds = pickZoneIdsForAlertsOut();

      const syncByIds = (zoneIds) => {
        const stmtUpsert = db.prepare(`
          INSERT INTO zone_active_alerts (zone_id, message, level, updated_at)
          VALUES (?, ?, 'WARNING', CURRENT_TIMESTAMP)
          ON CONFLICT(zone_id) DO UPDATE SET
            message = excluded.message,
            level = 'WARNING',
            updated_at = CURRENT_TIMESTAMP
        `);

        const stmtDelete = db.prepare(`DELETE FROM zone_active_alerts WHERE zone_id = ?`);
        const stmtInsertHistoryOnChange = db.prepare(`
          INSERT INTO zone_alerts (zone_id, zone_name, message, level, source)
          SELECT
            ?,
            COALESCE((SELECT name FROM zones WHERE id = ?), 'Zone ' || ?),
            ?,
            'WARNING',
            'LABVIEW'
          WHERE COALESCE((SELECT message FROM zone_active_alerts WHERE zone_id = ?), '') <> ?
        `);

        const stmtInsertZoneHistorySnapshotOnAlertChange = db.prepare(insertZoneHistorySnapshotOnAlertChangeSql);

        const emitted = [];

        let pending = 0;
        let finished = false;

        const maybeFinish = () => {
          if (finished) return;
          if (pending > 0) return;
          finished = true;

          stmtUpsert.finalize();
          stmtDelete.finalize();
          stmtInsertHistoryOnChange.finalize();
          stmtInsertZoneHistorySnapshotOnAlertChange.finalize();

          if (emitted.length) {
            const filtered = filterUniqueAlertChanges(emitted);

            if (filtered.length > 0) {
              io.emit("zone-alert", filtered);
              emitHistoryRealtime();
            }
          }
        };

        alertsOut.forEach((message, index) => {
          const zoneId = zoneIds[index];
          if (!zoneId) return;

          if (!message) {
            clearLastAlertSignatureForZone(zoneId, 'LABVIEW');
            clearLastAlertSignatureForZone(zoneId, 'ALERTS_OUT');
            pending += 1;
            stmtDelete.run([zoneId], () => {
              pending -= 1;
              maybeFinish();
            });
            return;
          }

          pending += 1;

          // Keep history aligned with dashboard active alerts, but avoid duplicates.
          // Important: do the history insert BEFORE updating zone_active_alerts.
          stmtInsertHistoryOnChange.run(
            [
              zoneId,
              zoneId,
              zoneId,
              message,
              zoneId,
              message
            ],
            () => {
              // Create a history row when an alert appears/changes (even if sensor values didn't change).
              stmtInsertZoneHistorySnapshotOnAlertChange.run(
                [
                  zoneId,
                  message,
                  zoneId,
                  message
                ],
                () => {
                  stmtUpsert.run([zoneId, message], () => {
                    pending -= 1;
                    maybeFinish();
                  });
                }
              );
            }
          );

          emitted.push({ zone_id: zoneId, message, level: 'WARNING', source: 'LABVIEW' });
        });

        maybeFinish();
      };

      if (payloadZoneIds.length) {
        syncByIds(payloadZoneIds);
      } else {
        db.all(`SELECT id FROM zones ORDER BY id ASC`, (idsErr, rows) => {
          if (idsErr) return;
          const dbIds = (rows || []).map((r) => toNullableNumber(r.id)).filter(Boolean);
          syncByIds(dbIds);
        });
      }
    }

    let labviewAuthoritativeZoneIds = null;

    if (Array.isArray(data.zone_config)) {
      // zone_config from LabVIEW dashboard is considered the source of truth for zone list.
      labviewAuthoritativeZoneIds = collectZoneIds(data.zone_config);
    }

    // ---------- MESURES ZONES ----------
    if(data.zone_measure){

      data.zone_measure.forEach((zone, index) => {

        const zoneId = getZoneId(zone, index);
        if (!zoneId) return;

        const humidity = toNullableNumber(pickFirst(zone, ['hum', 'humidity', 'h']));
        const temperature = toNullableNumber(pickFirst(zone, ['temp', 'temperature', 't']));
        const gaz = toNullableNumber(pickFirst(zone, ['gaz', 'nutrition', 'gas', 'n']));
        const light = toNullableNumber(pickFirst(zone, ['light', 'lux', 'l']));
        const zoneName = sanitizeIncomingZoneName(getZoneNameFromAnyShape(zone));

        const {
          thresholdHumidity,
          thresholdgaz,
          thresholdLight,
          thresholdTemperature
        } = getThresholdsFromAnyShape(zone);

        db.run(`
          INSERT INTO zones
          (id, name, humidity, temperature, gaz, light, thresholdHumidity, thresholdgaz, thresholdLight, thresholdTemperature, valve)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
          ON CONFLICT(id) DO UPDATE SET
            name = CASE
              WHEN NULLIF(TRIM(excluded.name), '') IS NULL THEN COALESCE(zones.name, 'Zone ' || zones.id)
              WHEN EXISTS (
                SELECT 1
                FROM zones z2
                WHERE z2.id <> zones.id
                  AND LOWER(TRIM(COALESCE(z2.name, ''))) = LOWER(TRIM(excluded.name))
              ) THEN COALESCE(zones.name, 'Zone ' || zones.id)
              ELSE TRIM(excluded.name)
            END,
            humidity = COALESCE(excluded.humidity, zones.humidity),
            temperature = COALESCE(excluded.temperature, zones.temperature),
            gaz = COALESCE(excluded.gaz, zones.gaz),
            light = COALESCE(excluded.light, zones.light),
            thresholdHumidity = COALESCE(excluded.thresholdHumidity, zones.thresholdHumidity, 30),
            thresholdgaz = COALESCE(excluded.thresholdgaz, zones.thresholdgaz, 50),
            thresholdLight = COALESCE(excluded.thresholdLight, zones.thresholdLight, 200),
            thresholdTemperature = COALESCE(excluded.thresholdTemperature, zones.thresholdTemperature, 25)
        `,
        [
          zoneId,
          zoneName,
          humidity,
          temperature,
          gaz,
          light,
          thresholdHumidity,
          thresholdgaz,
          thresholdLight,
          thresholdTemperature
        ]);

        // Historique uniquement si changement (valeurs / valve / mode).
        db.run(insertZoneHistorySnapshotIfChangedSql, [zoneId]);

      });

    }

    // ---------- SEUILS ZONES (payload dédié LabVIEW) ----------
    const thresholdPayloads = [
      data.zone_thresholds,
      data.zone_threshold,
      data.thresholds,
      data.zone_setpoints,
      data.setpoints,
      data.zone_config
    ].filter(Array.isArray);

    const thresholdObjectPayloads = [
      data.zone_thresholds,
      data.zone_threshold,
      data.thresholds,
      data.zone_setpoints,
      data.setpoints,
      data.zone_config
    ].filter((value) => value && typeof value === 'object' && !Array.isArray(value));

    thresholdObjectPayloads.forEach((payloadObject) => {
      Object.entries(payloadObject).forEach(([zoneKey, zoneThresholds]) => {
        const zoneId = toNullableNumber(zoneKey) ?? getZoneId(zoneThresholds, null);
        if (!zoneId) return;

        const {
          thresholdHumidity,
          thresholdgaz,
          thresholdLight,
          thresholdTemperature
        } = getThresholdsFromAnyShape(zoneThresholds || {});
        const {
          use_hum,
          use_temp,
          use_gaz,
          use_light,
          use_ev
        } = getZoneUsageFlagsFromAnyShape(zoneThresholds || {});
        const zoneName = applyZoneNameGuard(
          zoneId,
          sanitizeIncomingZoneName(getZoneNameFromAnyShape(zoneThresholds))
        );
        const evMode = parseEvModeOrNull(pickFirst(zoneThresholds || {}, ['mode', 'ev_mode', 'mode_ev', 'mode_status']));

        db.run(`
          INSERT INTO zones
          (id, name, humidity, temperature, gaz, light, thresholdHumidity, thresholdgaz, thresholdLight, thresholdTemperature, valve, ev_mode, use_hum, use_temp, use_gaz, use_light, use_ev)
          VALUES (?, ?, 0, 0, 0, 0, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            name = CASE
              WHEN NULLIF(TRIM(excluded.name), '') IS NULL THEN COALESCE(zones.name, 'Zone ' || zones.id)
              WHEN EXISTS (
                SELECT 1
                FROM zones z2
                WHERE z2.id <> zones.id
                  AND LOWER(TRIM(COALESCE(z2.name, ''))) = LOWER(TRIM(excluded.name))
              ) THEN COALESCE(zones.name, 'Zone ' || zones.id)
              ELSE TRIM(excluded.name)
            END,
            thresholdHumidity = COALESCE(excluded.thresholdHumidity, zones.thresholdHumidity, 30),
            thresholdgaz = COALESCE(excluded.thresholdgaz, zones.thresholdgaz, 50),
            thresholdLight = COALESCE(excluded.thresholdLight, zones.thresholdLight, 200),
            thresholdTemperature = COALESCE(excluded.thresholdTemperature, zones.thresholdTemperature, 25),
            ev_mode = COALESCE(excluded.ev_mode, zones.ev_mode, 'AUTO'),
            use_hum = COALESCE(excluded.use_hum, zones.use_hum, 1),
            use_temp = COALESCE(excluded.use_temp, zones.use_temp, 1),
            use_gaz = COALESCE(excluded.use_gaz, zones.use_gaz, 1),
            use_light = COALESCE(excluded.use_light, zones.use_light, 1),
            use_ev = COALESCE(excluded.use_ev, zones.use_ev, 1)
        `,
        [
          zoneId,
          zoneName,
          thresholdHumidity,
          thresholdgaz,
          thresholdLight,
          thresholdTemperature,
          evMode,
          use_hum,
          use_temp,
          use_gaz,
          use_light,
          use_ev
        ]);
      });
    });

    thresholdPayloads.forEach((thresholdList) => {
      thresholdList.forEach((zone, index) => {
        const zoneId = getZoneId(zone, index);
        if (!zoneId) return;

        const {
          thresholdHumidity,
          thresholdgaz,
          thresholdLight,
          thresholdTemperature
        } = getThresholdsFromAnyShape(zone);
        const {
          use_hum,
          use_temp,
          use_gaz,
          use_light,
          use_ev
        } = getZoneUsageFlagsFromAnyShape(zone);
        const zoneName = applyZoneNameGuard(
          zoneId,
          sanitizeIncomingZoneName(getZoneNameFromAnyShape(zone))
        );
        const evMode = parseEvModeOrNull(pickFirst(zone || {}, ['mode', 'ev_mode', 'mode_ev', 'mode_status']));

        db.run(`
          INSERT INTO zones
          (id, name, humidity, temperature, gaz, light, thresholdHumidity, thresholdgaz, thresholdLight, thresholdTemperature, valve, ev_mode, use_hum, use_temp, use_gaz, use_light, use_ev)
          VALUES (?, ?, 0, 0, 0, 0, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            name = CASE
              WHEN NULLIF(TRIM(excluded.name), '') IS NULL THEN COALESCE(zones.name, 'Zone ' || zones.id)
              WHEN EXISTS (
                SELECT 1
                FROM zones z2
                WHERE z2.id <> zones.id
                  AND LOWER(TRIM(COALESCE(z2.name, ''))) = LOWER(TRIM(excluded.name))
              ) THEN COALESCE(zones.name, 'Zone ' || zones.id)
              ELSE TRIM(excluded.name)
            END,
            thresholdHumidity = COALESCE(excluded.thresholdHumidity, zones.thresholdHumidity, 30),
            thresholdgaz = COALESCE(excluded.thresholdgaz, zones.thresholdgaz, 50),
            thresholdLight = COALESCE(excluded.thresholdLight, zones.thresholdLight, 200),
            thresholdTemperature = COALESCE(excluded.thresholdTemperature, zones.thresholdTemperature, 25),
            ev_mode = COALESCE(excluded.ev_mode, zones.ev_mode, 'AUTO'),
            use_hum = COALESCE(excluded.use_hum, zones.use_hum, 1),
            use_temp = COALESCE(excluded.use_temp, zones.use_temp, 1),
            use_gaz = COALESCE(excluded.use_gaz, zones.use_gaz, 1),
            use_light = COALESCE(excluded.use_light, zones.use_light, 1),
            use_ev = COALESCE(excluded.use_ev, zones.use_ev, 1)
        `,
        [
          zoneId,
          zoneName,
          thresholdHumidity,
          thresholdgaz,
          thresholdLight,
          thresholdTemperature,
          evMode,
          use_hum,
          use_temp,
          use_gaz,
          use_light,
          use_ev
        ]);
      });
    });

    // ---------- ETAT ELECTROVANNES ----------
    const processZoneRuntimeUpdates = (done) => {
      const runtimeItems = Array.isArray(data.zone_runtime)
        ? data.zone_runtime
        : (data.zone_runtime && typeof data.zone_runtime === 'object')
          ? Object.values(data.zone_runtime)
          : [];

      if (runtimeItems.length === 0) {
        done();
        return;
      }
      let index = 0;

      const next = () => {
        if (index >= runtimeItems.length) {
          done();
          return;
        }

        const runtime = runtimeItems[index];
        const runtimeIndex = index;
        index += 1;

        const zoneId = getZoneId(runtime, runtimeIndex) ?? (runtimeIndex + 1);
        const rawEvState = pickFirst(runtime, [
          'ev_status', 'ev_state', 'evState', 'valve', 'state'
        ]);
        const rawEvMode = pickFirst(runtime, ['mode', 'ev_mode', 'evMode', 'mode_ev']);

        const hasEvState =
          rawEvState !== undefined &&
          rawEvState !== null &&
          `${rawEvState}`.trim() !== '';
        const evState = hasEvState ? toBoolean(rawEvState) : null;
        const evMode = parseEvModeOrNull(rawEvMode);

        if (!hasEvState && !evMode) {
          next();
          return;
        }

        db.get(
          `SELECT valve, ev_mode FROM zones WHERE id = ?`,
          [zoneId],
          (_beforeErr, beforeRow) => {
            const previousValve = (toNullableNumber(beforeRow?.valve) ?? 0) === 1 ? 1 : 0;
            const previousMode = normalizeEvMode(beforeRow?.ev_mode || 'AUTO');
            const nextValve = hasEvState ? (evState ? 1 : 0) : previousValve;
            const nextMode = evMode ? normalizeEvMode(evMode) : previousMode;

            const updateSql = hasEvState
              ? `
                UPDATE zones
                SET valve = ?, ev_mode = COALESCE(?, ev_mode, 'AUTO')
                WHERE id = ?
              `
              : `
                UPDATE zones
                SET ev_mode = COALESCE(?, ev_mode, 'AUTO')
                WHERE id = ?
              `;

            const updateParams = hasEvState
              ? [nextValve, evMode, zoneId]
              : [evMode, zoneId];

            db.run(updateSql, updateParams, function(updateErr) {
              if (updateErr) {
                next();
                return;
              }

              const continueAfterUpdate = () => {
                db.run(insertZoneHistorySnapshotIfChangedSql, [zoneId], () => {
                  next();
                });
              };

              if (this.changes === 0) {
                // Ensure runtime-only payloads can still update/create the zone state.
                db.run(
                  `
                    INSERT INTO zones (id, name, valve, ev_mode)
                    VALUES (?, COALESCE((SELECT name FROM zones WHERE id = ?), 'Zone ' || ?), ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      valve = excluded.valve,
                      ev_mode = excluded.ev_mode
                  `,
                  [zoneId, zoneId, zoneId, nextValve, nextMode],
                  continueAfterUpdate
                );
                return;
              }

              const insertModeChangeIfNeeded = () => {
                if (!(evMode && previousMode !== nextMode)) {
                  continueAfterUpdate();
                  return;
                }
                db.run(
                  `
                    INSERT INTO commands (zone, valve, mode, event_type, status, alert_source)
                    VALUES (?, ?, ?, 'MODE_CHANGE', 'DONE', 'LABVIEW')
                  `,
                  [zoneId, nextValve, nextMode],
                  continueAfterUpdate
                );
              };

              if (hasEvState && previousValve !== nextValve) {
                db.run(
                  `
                    INSERT INTO commands (zone, valve, mode, event_type, status, alert_source)
                    VALUES (?, ?, ?, 'VALVE_CHANGE', 'DONE', 'LABVIEW')
                  `,
                  [zoneId, nextValve, nextMode],
                  insertModeChangeIfNeeded
                );
                return;
              }

              insertModeChangeIfNeeded();
            });
          }
        );
      };

      next();
    };

    const sendZonesToClients = () => {
      db.all(`
        SELECT
          z.*,
          zaa.message AS latest_alert_message,
          zaa.level AS latest_alert_level,
          zaa.updated_at AS latest_alert_created_at
        FROM zones z
        LEFT JOIN zone_active_alerts zaa ON zaa.zone_id = z.id
        ORDER BY z.id ASC
      `, (err, zones)=>{
        if (err) return res.status(500).json({ error: err.message });
        getAllZoneConfigs((newConfigErr, newZoneConfig) => {
          if (newConfigErr) return res.status(500).json({ error: newConfigErr.message });

          queueZoneConfigDiffEvents(
            {
              oldZoneConfig: oldZoneConfigForLabviewDiff || [],
              newZoneConfig: newZoneConfig || [],
              source: 'LABVIEW'
            },
            (diffErr) => {
              if (diffErr) return res.status(500).json({ error: diffErr.message });
              io.emit("zones-update", zones || []);
              emitZoneConfigUpdate();
              emitHistoryRealtime();
              res.json({status:"LABVIEW DATA RECEIVED"});
            }
          );
        });
      });
    };

    const finalizeSyncAndEmit = () => {
      if (labviewAuthoritativeZoneIds !== null) {
        if (!labviewAuthoritativeZoneIds.length) {
          db.run(`DELETE FROM zones`, (deleteErr) => {
            if (deleteErr) return res.status(500).json({ error: deleteErr.message });
            sendZonesToClients();
          });
        } else {
          const placeholders = labviewAuthoritativeZoneIds.map(() => '?').join(', ');
          db.run(
            `DELETE FROM zones WHERE id NOT IN (${placeholders})`,
            labviewAuthoritativeZoneIds,
            (deleteErr) => {
              if (deleteErr) return res.status(500).json({ error: deleteErr.message });
              sendZonesToClients();
            }
          );
        }
        return;
      }

      // ---------- ENVOI MOBILE ----------
      sendZonesToClients();
    };

    processZoneRuntimeUpdates(finalizeSyncAndEmit);

  });

});

// =======================
// MOBILE → DASHBOARD
// =======================

app.get('/dashboard', requireAuth, (req, res) => {

  db.get(`
    SELECT * FROM environment
    ORDER BY id DESC LIMIT 1
  `, (envErr, environment) => {
    if (envErr) return res.status(500).json({ error: envErr.message });

    db.all(`
      SELECT
        z.*,
        zaa.message AS latest_alert_message,
        zaa.level AS latest_alert_level,
        zaa.updated_at AS latest_alert_created_at
      FROM zones z
      LEFT JOIN zone_active_alerts zaa ON zaa.zone_id = z.id
      ORDER BY z.id ASC
    `, (zonesErr, zones) => {
      if (zonesErr) return res.status(500).json({ error: zonesErr.message });

      getDosingConfig((dosingErr, dosingConfig) => {
        if (dosingErr) return res.status(500).json({ error: dosingErr.message });

        getTankCapacityLiters((capacityErr, tankCapacityLiters) => {
          if (capacityErr) return res.status(500).json({ error: capacityErr.message });

          let dosagePlan = null;
          const validationError = validateDosingConfig(dosingConfig);
          if (!validationError) {
            const waterLiters = computeWaterLitersFromEnvironment(environment || {}, tankCapacityLiters);
            if (waterLiters != null) {
              try {
                const plan = computeDosingPlan({
                  waterLiters,
                  configByProduct: dosingConfig
                });
                dosagePlan = {
                  ...plan,
                  water_level_percent: toNullableNumber(environment?.water_level),
                  tank_capacity_liters: tankCapacityLiters
                };
              } catch (_) {
                dosagePlan = null;
              }
            }
          }

          res.json({
            environment: environment || {},
            zones: zones || [],
            zone_config: (zones || []).map(normalizeZoneConfig),
            dosage_config: dosingConfig,
            tank_capacity_liters: tankCapacityLiters,
            dosage_plan: dosagePlan
          });
        });
      });
    });
  });
});

app.get('/alerts', requireAuth, (_req, res) => {
  db.all(
    `
      SELECT id, zone_id, zone_name, message, level, source, created_at
      FROM zone_alerts
      ORDER BY created_at DESC, id DESC
      LIMIT 200
    `,
    (err, rows) => {
      if (err) return res.status(500).json({ error: err.message });
      res.json(rows || []);
    }
  );
});

app.get('/zone-config', requireAuth, (_req, res) => {
  getAllZoneConfigs((err, zoneConfig) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ zone_config: zoneConfig || [] });
  });
});

app.get('/dosage-config', requireAuth, (_req, res) => {
  getDosingConfig((err, configByProduct) => {
    if (err) return res.status(500).json({ error: err.message });

    getTankCapacityLiters((capacityErr, tankCapacityLiters) => {
      if (capacityErr) return res.status(500).json({ error: capacityErr.message });
      res.json({
        dosage_config: configByProduct || {},
        tank_capacity_liters: tankCapacityLiters
      });
    });
  });
});

app.post('/dosage-config', requireAuth, (req, res) => {
  const configByProduct = extractDosingConfigFromPayload(req.body || {});
  const requestedTankCapacityLiters = parseTankCapacityLitersFromPayload(req.body || {});
  const validationError = validateDosingConfig(configByProduct);
  if (validationError) {
    return res.status(400).json({ error: validationError });
  }
  if (Number.isNaN(requestedTankCapacityLiters)) {
    return res.status(400).json({ error: 'tank_capacity_liters invalide' });
  }

  upsertDosingConfig(configByProduct, (err) => {
    if (err) return res.status(500).json({ error: err.message });

    const withCapacity = (tankCapacityLiters) => {
      db.get(`SELECT * FROM environment ORDER BY id DESC LIMIT 1`, (_envErr, environment) => {
        let dosagePlan = null;
        const waterLiters = computeWaterLitersFromEnvironment(environment || {}, tankCapacityLiters);

        if (waterLiters != null) {
          try {
            dosagePlan = {
              ...computeDosingPlan({
                waterLiters,
                configByProduct
              }),
              water_level_percent: toNullableNumber(environment?.water_level),
              tank_capacity_liters: tankCapacityLiters
            };
          } catch (_) {
            dosagePlan = null;
          }
        }

        return res.json({
          status: 'Dosage configuration updated',
          dosage_config: configByProduct,
          tank_capacity_liters: tankCapacityLiters,
          dosage_plan: dosagePlan
        });
      });
    };

    if (requestedTankCapacityLiters != null) {
      return upsertTankCapacityLiters(requestedTankCapacityLiters, (capacityErr) => {
        if (capacityErr) return res.status(500).json({ error: capacityErr.message });
        return withCapacity(requestedTankCapacityLiters);
      });
    }

    return getTankCapacityLiters((capacityErr, tankCapacityLiters) => {
      if (capacityErr) return res.status(500).json({ error: capacityErr.message });
      return withCapacity(tankCapacityLiters);
    });
  });
});

app.post('/dosage/calculate', requireAuth, (req, res) => {
  const sourceConfig = req.body && typeof req.body === 'object' && req.body.dosage_config
    ? extractDosingConfigFromPayload(req.body)
    : null;
  const requestedTankCapacityLiters = parseTankCapacityLitersFromPayload(req.body || {});
  if (Number.isNaN(requestedTankCapacityLiters)) {
    return res.status(400).json({ error: 'tank_capacity_liters invalide' });
  }

  const computeAndReply = (
    configByProduct,
    waterLiters,
    waterLevelPercent = null,
    tankCapacityLiters = TANK_CAPACITY_L
  ) => {
    const validationError = validateDosingConfig(configByProduct);
    if (validationError) {
      return res.status(400).json({ error: validationError });
    }

    if (waterLiters == null || !Number.isFinite(waterLiters) || waterLiters < 0) {
      return res.status(400).json({ error: 'water_liters invalide' });
    }

    try {
      const plan = computeDosingPlan({
        waterLiters,
        configByProduct
      });

      return res.json({
        dosage_plan: {
          ...plan,
          water_level_percent: waterLevelPercent,
          tank_capacity_liters: tankCapacityLiters
        }
      });
    } catch (error) {
      return res.status(400).json({ error: error.message || 'Calcul dosage impossible' });
    }
  };

  const resolveTankCapacity = (callback) => {
    if (requestedTankCapacityLiters != null) {
      return callback(null, requestedTankCapacityLiters);
    }
    return getTankCapacityLiters(callback);
  };

  const requestedWaterLiters = toNullableNumber(req.body?.water_liters);
  if (sourceConfig) {
    resolveTankCapacity((capacityErr, tankCapacityLiters) => {
      if (capacityErr) return res.status(500).json({ error: capacityErr.message });

      if (requestedWaterLiters != null) {
        return computeAndReply(sourceConfig, requestedWaterLiters, null, tankCapacityLiters);
      }

      db.get(`SELECT water_level FROM environment ORDER BY id DESC LIMIT 1`, (envErr, environment) => {
        if (envErr) return res.status(500).json({ error: envErr.message });
        const waterLiters = computeWaterLitersFromEnvironment(environment || {}, tankCapacityLiters);
        return computeAndReply(
          sourceConfig,
          waterLiters,
          toNullableNumber(environment?.water_level),
          tankCapacityLiters
        );
      });
    });
    return;
  }

  getDosingConfig((cfgErr, configByProduct) => {
    if (cfgErr) return res.status(500).json({ error: cfgErr.message });

    resolveTankCapacity((capacityErr, tankCapacityLiters) => {
      if (capacityErr) return res.status(500).json({ error: capacityErr.message });

      if (requestedWaterLiters != null) {
        return computeAndReply(configByProduct, requestedWaterLiters, null, tankCapacityLiters);
      }

      db.get(`SELECT water_level FROM environment ORDER BY id DESC LIMIT 1`, (envErr, environment) => {
        if (envErr) return res.status(500).json({ error: envErr.message });
        const waterLiters = computeWaterLitersFromEnvironment(environment || {}, tankCapacityLiters);
        return computeAndReply(
          configByProduct,
          waterLiters,
          toNullableNumber(environment?.water_level),
          tankCapacityLiters
        );
      });
    });
  });
});


// =======================
// MOBILE → ENVOIE COMMANDE
// =======================

app.post('/command', requireAuth, (req, res) => {
  const zoneId = toNullableNumber(pickFirst(req.body || {}, ['zone', 'zone_id', 'zoneId', 'id']));
  const rawMode = pickFirst(req.body || {}, ['mode', 'ev_mode', 'evMode', 'mode_ev', 'mode_status']);
  const rawValve = pickFirst(req.body || {}, [
    'valve', 'ev_state', 'evState', 'valve_on', 'isOpen', 'ev', 'state', 'command'
  ]);
  const hasExplicitValveIntent =
    pickFirst(req.body || {}, ['ev_state', 'evState', 'valve_on', 'isOpen', 'ev', 'state', 'command']) !== undefined;

  const hasMode = rawMode !== undefined && rawMode !== null && `${rawMode}`.trim() !== '';
  const hasValve = rawValve !== undefined && rawValve !== null && `${rawValve}`.trim() !== '';
  const normalizedMode = hasMode ? parseEvModeOrNull(rawMode) : null;
  const normalizedValve = hasValve ? (toBoolean(rawValve) ? 1 : 0) : null;
  const eventType = hasValve && (!hasMode || hasExplicitValveIntent)
    ? 'VALVE_CHANGE'
    : hasMode
      ? 'MODE_CHANGE'
      : 'COMMAND';
  const valveForCommand = eventType === 'VALVE_CHANGE' ? normalizedValve ?? 0 : null;

  if (zoneId == null) {
    return res.status(400).json({ error: "zone is required" });
  }

  if (!hasMode && !hasValve) {
    return res.status(400).json({ error: "mode or valve is required" });
  }

  if (hasMode && !normalizedMode) {
    return res.status(400).json({ error: "mode must be AUTO or MANUAL" });
  }

  db.run(`
    INSERT INTO commands (zone, valve, mode, event_type, alert_source)
    VALUES (?, ?, ?, ?, 'MOBILE')
  `, [zoneId, valveForCommand, normalizedMode, eventType], (err) => {
    if (err) return res.status(500).json({ error: err.message });

    const updateSql = hasMode
      ? `
        UPDATE zones
        SET ev_mode = ?,
            valve = CASE
              WHEN ? = 'MANUAL' AND ? IS NOT NULL THEN ?
              ELSE valve
            END
        WHERE id = ?
      `
      : `
        UPDATE zones
        SET valve = ?
        WHERE id = ?
      `;

    const updateParams = hasMode
      ? [normalizedMode, normalizedMode, normalizedValve, normalizedValve, zoneId]
      : [normalizedValve, zoneId];

    db.run(updateSql, updateParams, function(updateErr) {
      if (updateErr) return res.status(500).json({ error: updateErr.message });
      if (this.changes === 0) return res.status(404).json({ error: "Zone not found" });

      // Historiser le changement de mode/valve seulement si changement réel.
      db.run(insertZoneHistorySnapshotIfChangedSql, [zoneId]);

      db.all(`SELECT * FROM zones`, (zonesErr, zones) => {
        if (zonesErr) return res.status(500).json({ error: zonesErr.message });
        io.emit("zones-update", zones || []);
        emitZoneConfigUpdate();
        emitHistoryRealtime();
        res.json({ status: "Command created" });
      });
    });
  });
});


// =======================
// LABVIEW → LECTURE COMMANDE
// =======================

app.get('/command', (req, res) => {

  db.get(`
    SELECT * FROM commands
    WHERE status = 'NEW'
    ORDER BY id ASC LIMIT 1
  `, (err, cmd) => {
    if (err) return res.status(500).json({ error: err.message });

    if (!cmd) return res.json({});

    db.run(`
      UPDATE commands SET status = 'DONE'
      WHERE id = ?
    `, [cmd.id]);

    res.json(cmd);
  });
});

// =======================
// LABVIEW → LECTURE COMMANDE (JSON NORMALISE)
// =======================

app.get('/labview/command', (req, res) => {

  db.get(`
    SELECT * FROM commands
    WHERE status = 'NEW'
    ORDER BY id ASC LIMIT 1
  `, (err, cmd) => {
    if (err) return res.status(500).json({ ok: false, error: err.message });
    if (!cmd) return res.json(formatLabviewCommand(null));

    db.run(`
      UPDATE commands SET status = 'DONE'
      WHERE id = ?
    `, [cmd.id], (updateErr) => {
      if (updateErr) return res.status(500).json({ ok: false, error: updateErr.message });

      db.all(`SELECT * FROM zones ORDER BY id ASC`, (zonesErr, allZones) => {
        if (zonesErr) return res.status(500).json({ ok: false, error: zonesErr.message });

        const zoneRow = (allZones || []).find((zone) => zone.id === cmd.zone) || null;
        res.json(formatLabviewCommand(cmd, zoneRow, allZones || []));
      });
    });
  });
});


const broadcastZonesAndRespond = (res, payload) => {
  db.all(`SELECT * FROM zones ORDER BY id ASC`, (zonesErr, zones) => {
    if (zonesErr) return res.status(500).json({ error: zonesErr.message });
    io.emit("zones-update", zones || []);
    emitZoneConfigUpdate();
    res.json({
      ...payload,
      zones: zones || []
    });
  });
};

const getAllZoneConfigs = (callback) => {
  db.all(`SELECT * FROM zones ORDER BY id ASC`, (err, rows) => {
    if (err) return callback(err);
    callback(null, (rows || []).map(normalizeZoneConfig));
  });
};

const emitZoneConfigUpdate = () => {
  getAllZoneConfigs((err, zoneConfig) => {
    if (err) {
      console.error('zone-config realtime emit error:', err.message);
      return;
    }

    io.emit('zone-config-update', zoneConfig || []);
  });
};

const queueCommandWithZoneConfig = ({ zone, valve, mode, eventType, oldZoneConfig, newZoneConfig, source }, callback) => {
  db.run(`
    INSERT INTO commands (zone, valve, mode, event_type, old_zone_config, new_zone_config, alert_source)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `,
  [
    zone,
    valve,
    mode,
    eventType || null,
    JSON.stringify(oldZoneConfig || []),
    JSON.stringify(newZoneConfig || []),
    (source || 'MOBILE').toString().trim().toUpperCase()
  ],
  callback);
};

const normalizeConfigZoneForDiff = (zone) => {
  const zoneId = toNullableNumber(getZoneId(zone));
  if (zoneId == null) return null;

  const thresholds = getThresholdsFromAnyShape(zone || {});
  const usage = getZoneUsageFlagsFromAnyShape(zone || {});

  return {
    id: zoneId,
    name: normalizeZoneName(getZoneNameFromAnyShape(zone), zoneId) || `Zone ${zoneId}`,
    ev_mode: normalizeEvMode(pickFirst(zone || {}, ['mode', 'ev_mode', 'evMode', 'mode_ev', 'mode_status'])),
    thresholdHumidity: toNullableNumber(thresholds.thresholdHumidity),
    thresholdgaz: toNullableNumber(thresholds.thresholdgaz),
    thresholdLight: toNullableNumber(thresholds.thresholdLight),
    thresholdTemperature: toNullableNumber(thresholds.thresholdTemperature),
    use_hum: usage.use_hum,
    use_temp: usage.use_temp,
    use_gaz: usage.use_gaz,
    use_light: usage.use_light,
    use_ev: usage.use_ev
  };
};

const sameNumberOrNull = (a, b) => {
  const left = toNullableNumber(a);
  const right = toNullableNumber(b);
  if (left == null && right == null) return true;
  return left === right;
};

const getActiveAlertSnapshotForZone = (zoneId, callback) => {
  db.get(
    `
      SELECT message, level, updated_at
      FROM zone_active_alerts
      WHERE zone_id = ?
      LIMIT 1
    `,
    [zoneId],
    (err, row) => {
      if (err) return callback(err);
      callback(null, row
        ? {
          message: row.message,
          level: row.level,
          source: 'LABVIEW',
          updated_at: row.updated_at
        }
        : null
      );
    }
  );
};

const queueZoneConfigDiffEvents = ({ oldZoneConfig, newZoneConfig, source }, callback) => {
  const normalizedSource = (source || 'LABVIEW').toString().trim().toUpperCase();
  const oldById = new Map(
    (oldZoneConfig || [])
      .map((zone) => normalizeConfigZoneForDiff(zone))
      .filter(Boolean)
      .map((zone) => [zone.id, zone])
  );
  const newById = new Map(
    (newZoneConfig || [])
      .map((zone) => normalizeConfigZoneForDiff(zone))
      .filter(Boolean)
      .map((zone) => [zone.id, zone])
  );

  const zoneIds = [...new Set([...oldById.keys(), ...newById.keys()])].sort((a, b) => a - b);
  const tasks = [];

  zoneIds.forEach((zoneId) => {
    const previous = oldById.get(zoneId) || null;
    const current = newById.get(zoneId) || null;
    if (!previous || !current) return;

    const nameChanged = (previous.name || '').trim() !== (current.name || '').trim();

    if (previous.ev_mode !== current.ev_mode) {
      tasks.push((next) => {
        getActiveAlertSnapshotForZone(zoneId, (alertErr, alertSnapshot) => {
          if (alertErr) return next(alertErr);

          db.run(
            `
              INSERT INTO commands (
                zone, valve, mode, event_type, status, old_zone_config, new_zone_config,
                alert_message, alert_level, alert_source, alert_created_at
              )
              VALUES (?, ?, ?, ?, 'DONE', ?, ?, ?, ?, ?, ?)
            `,
            [
              zoneId,
              0,
              current.ev_mode,
              'MODE_CHANGE',
              JSON.stringify([previous]),
              JSON.stringify([current]),
              alertSnapshot?.message || null,
              alertSnapshot?.level || null,
              normalizedSource,
                alertSnapshot?.updated_at || null
              ],
              next
            );
          });
      });
    }

    if (nameChanged) {
      tasks.push((next) => {
        getActiveAlertSnapshotForZone(zoneId, (alertErr, alertSnapshot) => {
          if (alertErr) return next(alertErr);

          db.run(
            `
              INSERT INTO commands (
                zone, valve, mode, event_type, status, old_zone_config, new_zone_config,
                alert_message, alert_level, alert_source, alert_created_at
              )
              VALUES (?, ?, ?, ?, 'DONE', ?, ?, ?, ?, ?, ?)
            `,
            [
              zoneId,
              0,
              'UPDATE_ZONE_NAME',
              'NAME_CHANGE',
              JSON.stringify([previous]),
              JSON.stringify([current]),
              alertSnapshot?.message || null,
              alertSnapshot?.level || null,
              normalizedSource,
                alertSnapshot?.updated_at || null
              ],
              next
            );
          });
      });
    }

    const thresholdsChanged =
      !sameNumberOrNull(previous.thresholdHumidity, current.thresholdHumidity) ||
      !sameNumberOrNull(previous.thresholdgaz, current.thresholdgaz) ||
      !sameNumberOrNull(previous.thresholdLight, current.thresholdLight) ||
      !sameNumberOrNull(previous.thresholdTemperature, current.thresholdTemperature);

    if (thresholdsChanged) {
      tasks.push((next) => {
        getActiveAlertSnapshotForZone(zoneId, (alertErr, alertSnapshot) => {
          if (alertErr) return next(alertErr);

          db.run(
            `
              INSERT INTO commands (
                zone, valve, mode, event_type, status, old_zone_config, new_zone_config,
                alert_message, alert_level, alert_source, alert_created_at
              )
              VALUES (?, ?, ?, ?, 'DONE', ?, ?, ?, ?, ?, ?)
            `,
            [
              zoneId,
              0,
              'UPDATE_THRESHOLDS',
              'THRESHOLD_CHANGE',
              JSON.stringify([previous]),
              JSON.stringify([current]),
              alertSnapshot?.message || null,
              alertSnapshot?.level || null,
              normalizedSource,
                alertSnapshot?.updated_at || null
              ],
              next
            );
          });
      });
    }

    const sensorsChanged =
      !sameNumberOrNull(previous.use_hum, current.use_hum) ||
      !sameNumberOrNull(previous.use_temp, current.use_temp) ||
      !sameNumberOrNull(previous.use_gaz, current.use_gaz) ||
      !sameNumberOrNull(previous.use_light, current.use_light) ||
      !sameNumberOrNull(previous.use_ev, current.use_ev);

    if (sensorsChanged) {
      tasks.push((next) => {
        getActiveAlertSnapshotForZone(zoneId, (alertErr, alertSnapshot) => {
          if (alertErr) return next(alertErr);

          db.run(
            `
              INSERT INTO commands (
                zone, valve, mode, event_type, status, old_zone_config, new_zone_config,
                alert_message, alert_level, alert_source, alert_created_at
              )
              VALUES (?, ?, ?, ?, 'DONE', ?, ?, ?, ?, ?, ?)
            `,
            [
              zoneId,
              0,
              'SYNC_ZONE_CONFIG',
              'SENSOR_CONFIG_CHANGE',
              JSON.stringify([previous]),
              JSON.stringify([current]),
              alertSnapshot?.message || null,
              alertSnapshot?.level || null,
              normalizedSource,
                alertSnapshot?.updated_at || null
              ],
              next
            );
          });
      });
    }
  });

  if (!tasks.length) {
    if (callback) callback(null);
    return;
  }

  let index = 0;
  const runNext = (err) => {
    if (err) {
      if (callback) callback(err);
      return;
    }

    if (index >= tasks.length) {
      if (callback) callback(null);
      return;
    }

    const task = tasks[index];
    index += 1;
    task(runNext);
  };

  runNext();
};

const addZoneInternal = ({ requestedId, zoneName, zoneConfig, shouldQueueCommand, commandMode, source }, res) => {
  const parsedId = toNullableNumber(requestedId);
  const zoneId = parsedId != null ? Math.trunc(parsedId) : null;
  const normalizedName = normalizeZoneName(zoneName, zoneId);
  const {
    thresholdHumidity,
    thresholdgaz,
    thresholdLight,
    thresholdTemperature
  } = getThresholdsFromAnyShape(zoneConfig || {});
  const {
    use_hum,
    use_temp,
    use_gaz,
    use_light,
    use_ev
  } = getZoneUsageFlagsFromAnyShape(zoneConfig || {});
  const evMode = parseEvModeOrNull(pickFirst(zoneConfig || {}, ['mode', 'ev_mode', 'mode_ev', 'mode_status']));

  const withExplicitId = zoneId != null;
  const insertSql = withExplicitId
    ? `
      INSERT INTO zones
      (id, name, humidity, temperature, gaz, light,
       thresholdHumidity, thresholdgaz,
       thresholdLight, thresholdTemperature, valve, ev_mode,
       use_hum, use_temp, use_gaz, use_light, use_ev)
      VALUES (?, ?, 0, 0, 0, 0, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
    `
    : `
      INSERT INTO zones
      (name, humidity, temperature, gaz, light,
       thresholdHumidity, thresholdgaz,
       thresholdLight, thresholdTemperature, valve, ev_mode,
       use_hum, use_temp, use_gaz, use_light, use_ev)
      VALUES (?, 0, 0, 0, 0, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
    `;

  const params = withExplicitId
    ? [
      zoneId,
      normalizedName,
      thresholdHumidity ?? 30,
      thresholdgaz ?? 50,
      thresholdLight ?? 200,
      thresholdTemperature ?? 25,
      evMode || 'AUTO',
      use_hum ?? 1,
      use_temp ?? 1,
      use_gaz ?? 1,
      use_light ?? 1,
      use_ev ?? 1
    ]
    : [
      normalizedName,
      thresholdHumidity ?? 30,
      thresholdgaz ?? 50,
      thresholdLight ?? 200,
      thresholdTemperature ?? 25,
      evMode || 'AUTO',
      use_hum ?? 1,
      use_temp ?? 1,
      use_gaz ?? 1,
      use_light ?? 1,
      use_ev ?? 1
    ];

  const executeInsert = (oldZoneConfig) => {
    db.run(insertSql, params, function(err) {
      if (err) {
        return res.status(500).json({ error: err.message });
      }

      const newZoneId = withExplicitId ? zoneId : this.lastID;
      const action = commandMode || 'ADD_ZONE';
      const finalName = normalizeZoneName(zoneName, newZoneId);

      const afterNameReady = () => {
        const finish = () => broadcastZonesAndRespond(res, {
          status: "Zone added",
          id: newZoneId,
          name: finalName,
          zone: newZoneId,
          zone_id: newZoneId,
          action,
          ok: true,
          source
        });

        if (!shouldQueueCommand) return finish();

        getAllZoneConfigs((newErr, newZoneConfig) => {
          if (newErr) return res.status(500).json({ error: newErr.message });

        queueCommandWithZoneConfig({
          zone: newZoneId,
          valve: 0,
          mode: commandMode,
          eventType: 'SENSOR_CONFIG_CHANGE',
          oldZoneConfig,
          newZoneConfig,
          source: 'MOBILE'
        }, (cmdErr) => {
            if (cmdErr) return res.status(500).json({ error: cmdErr.message });
            finish();
          });
        });
      };

      if (normalizedName === finalName) return afterNameReady();

      db.run(`UPDATE zones SET name = ? WHERE id = ?`, [finalName, newZoneId], (nameErr) => {
        if (nameErr) return res.status(500).json({ error: nameErr.message });
        afterNameReady();
      });
    });
  };

  findZoneByName({ name: normalizedName }, (nameErr, existingZone) => {
    if (nameErr) return res.status(500).json({ error: nameErr.message });
    if (existingZone) {
      return res.status(409).json({ error: 'Zone name already exists' });
    }

    if (!shouldQueueCommand) {
      executeInsert([]);
      return;
    }

    getAllZoneConfigs((oldErr, oldZoneConfig) => {
      if (oldErr) return res.status(500).json({ error: oldErr.message });
      executeInsert(oldZoneConfig);
    });
  });
};

const removeZoneInternal = ({ id, shouldQueueCommand, commandMode, source }, res) => {
  const parsedId = toNullableNumber(id);
  const zoneId = parsedId != null ? Math.trunc(parsedId) : null;

  if (!zoneId) {
    return res.status(400).json({ error: "id is required" });
  }

  const executeRemove = (oldZoneConfig) => {
    db.run(`DELETE FROM zones WHERE id = ?`, [zoneId], function(err) {
      if (err) return res.status(500).json({ error: err.message });
      if (this.changes === 0) return res.status(404).json({ error: "Zone not found" });

      const action = commandMode || 'REMOVE_ZONE';

      const finish = () => broadcastZonesAndRespond(res, {
        status: "Zone removed",
        id: zoneId,
        zone: zoneId,
        zone_id: zoneId,
        action,
        ok: true,
        source
      });

      io.emit("zone-removed", {
        id: zoneId,
        zone: zoneId,
        zone_id: zoneId,
        action,
        source: source || 'SERVER'
      });

      if (!shouldQueueCommand) return finish();

      getAllZoneConfigs((newErr, newZoneConfig) => {
        if (newErr) return res.status(500).json({ error: newErr.message });

        queueCommandWithZoneConfig({
          zone: zoneId,
          valve: 0,
          mode: commandMode,
          eventType: 'SENSOR_CONFIG_CHANGE',
          oldZoneConfig,
          newZoneConfig,
          source: 'MOBILE'
        }, (cmdErr) => {
          if (cmdErr) return res.status(500).json({ error: cmdErr.message });
          finish();
        });
      });
    });
  };

  if (!shouldQueueCommand) return executeRemove([]);

  getAllZoneConfigs((oldErr, oldZoneConfig) => {
    if (oldErr) return res.status(500).json({ error: oldErr.message });
    executeRemove(oldZoneConfig);
  });
};

app.post('/add-zone', requireAuth, (req, res) => {
  addZoneInternal({
    requestedId: req.body?.id,
    zoneName: req.body?.name,
    zoneConfig: req.body,
    shouldQueueCommand: true,
    commandMode: 'ADD_ZONE',
    source: 'FLUTTER'
  }, res);

});

app.post('/remove-zone', requireAuth, (req, res) => {
  removeZoneInternal({
    id: req.body?.id,
    shouldQueueCommand: true,
    commandMode: 'REMOVE_ZONE',
    source: 'FLUTTER'
  }, res);

});
app.post('/update-thresholds', requireAuth, (req, res) => {

  const id = pickFirst(req.body || {}, ['id', 'zone_id', 'zoneId']);
  const thresholdHumidity = getThresholdHumidity(req.body || {});
  const thresholdgaz = getThresholdgaz(req.body || {});
  const thresholdLight = getThresholdLight(req.body || {});
  const thresholdTemperature = getThresholdTemperature(req.body || {});
  const evMode = parseEvModeOrNull(pickFirst(req.body || {}, ['mode', 'ev_mode', 'mode_ev', 'mode_status']));
  const {
    use_hum,
    use_temp,
    use_gaz,
    use_light,
    use_ev
  } = getZoneUsageFlagsFromAnyShape(req.body || {});

  const zoneId = toNullableNumber(id);
  if (zoneId == null) {
    return res.status(400).json({ error: "id is required" });
  }

  getAllZoneConfigs((oldErr, oldZoneConfig) => {
    if (oldErr) return res.status(500).json({ error: oldErr.message });

    db.run(`
      UPDATE zones
      SET thresholdHumidity = COALESCE(?, thresholdHumidity, 30),
          thresholdgaz = COALESCE(?, thresholdgaz, 50),
          thresholdLight = COALESCE(?, thresholdLight, 200),
          thresholdTemperature = COALESCE(?, thresholdTemperature, 25),
          ev_mode = COALESCE(?, ev_mode, 'AUTO'),
          use_hum = COALESCE(?, use_hum, 1),
          use_temp = COALESCE(?, use_temp, 1),
          use_gaz = COALESCE(?, use_gaz, 1),
          use_light = COALESCE(?, use_light, 1),
          use_ev = COALESCE(?, use_ev, 1)
      WHERE id = ?
    `,
    [
      thresholdHumidity,
      thresholdgaz,
      thresholdLight,
      thresholdTemperature,
      evMode,
      use_hum,
      use_temp,
      use_gaz,
      use_light,
      use_ev,
      zoneId
    ],
    function(err) {

      if (err) return res.status(500).json({ error: err.message });
      if (this.changes === 0) return res.status(404).json({ error: "Zone not found" });

      getAllZoneConfigs((newErr, newZoneConfig) => {
        if (newErr) return res.status(500).json({ error: newErr.message });

        queueCommandWithZoneConfig({
          zone: zoneId,
          valve: 0,
          mode: 'UPDATE_THRESHOLDS',
          eventType: 'THRESHOLD_CHANGE',
          oldZoneConfig,
          newZoneConfig,
          source: 'MOBILE'
        }, (cmdErr) => {
          if (cmdErr) return res.status(500).json({ error: cmdErr.message });

          db.all(`SELECT * FROM zones`, (zonesErr, zones) => {
            if (zonesErr) return res.status(500).json({ error: zonesErr.message });
            io.emit("zones-update", zones || []);
            emitZoneConfigUpdate();
            res.json({
              status: "Thresholds updated",
              zone_config: newZoneConfig
            });
          });
        });
      });

    });
  });

});
app.post('/update-zone-name', requireAuth, (req, res) => {

  const { id, name } = req.body;
  const zoneId = toNullableNumber(id);
  const trimmedName = typeof name === 'string' ? name.trim() : '';

  if (zoneId == null) {
    return res.status(400).json({ error: "id is required" });
  }

  if (!trimmedName) {
    return res.status(400).json({ error: "name is required" });
  }

  findZoneByName({ name: trimmedName, excludeZoneId: zoneId }, (nameErr, existingZone) => {
    if (nameErr) return res.status(500).json({ error: nameErr.message });
    if (existingZone) {
      return res.status(409).json({ error: 'Zone name already exists' });
    }

    getAllZoneConfigs((oldErr, oldZoneConfig) => {
      if (oldErr) return res.status(500).json({ error: oldErr.message });

      db.run(`
        UPDATE zones
        SET name = ?
        WHERE id = ?
      `,
      [trimmedName, zoneId],
      function(err){

        if (err) return res.status(500).json({ error: err.message });
        if (this.changes === 0) return res.status(404).json({ error: "Zone not found" });
        setMobileNameGuard(zoneId, trimmedName);

        getAllZoneConfigs((newErr, newZoneConfig) => {
          if (newErr) return res.status(500).json({ error: newErr.message });

          queueCommandWithZoneConfig({
            zone: zoneId,
            valve: 0,
            mode: 'UPDATE_ZONE_NAME',
            eventType: 'NAME_CHANGE',
            oldZoneConfig,
            newZoneConfig,
            source: 'MOBILE'
          }, (cmdErr) => {
            if (cmdErr) return res.status(500).json({ error: cmdErr.message });

            db.all(`SELECT * FROM zones`, (zonesErr, zones) => {
              if (zonesErr) return res.status(500).json({ error: zonesErr.message });
              io.emit("zones-update", zones || []);
              emitZoneConfigUpdate();

              res.json({
                status: "Zone name updated",
                zone_config: newZoneConfig
              });
            });
          });
        });
      });
    });
  });

});

app.post('/sync-zone-config', requireAuth, (req, res) => {
  const incoming = Array.isArray(req.body)
    ? req.body
    : Array.isArray(req.body?.zone_config)
      ? req.body.zone_config
      : [];

  if (!incoming.length) {
    return res.status(400).json({ error: 'zone_config[] is required' });
  }

  getAllZoneConfigs((oldErr, oldZoneConfig) => {
    if (oldErr) return res.status(500).json({ error: oldErr.message });

    const stmt = db.prepare(`
      INSERT INTO zones
      (id, name, humidity, temperature, gaz, light,
       thresholdHumidity, thresholdgaz, thresholdLight, thresholdTemperature,
       valve, ev_mode, use_hum, use_temp, use_gaz, use_light, use_ev)
      VALUES (?, ?, 0, 0, 0, 0, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = CASE
          WHEN NULLIF(TRIM(excluded.name), '') IS NULL THEN COALESCE(zones.name, 'Zone ' || zones.id)
          WHEN EXISTS (
            SELECT 1
            FROM zones z2
            WHERE z2.id <> zones.id
              AND LOWER(TRIM(COALESCE(z2.name, ''))) = LOWER(TRIM(excluded.name))
          ) THEN COALESCE(zones.name, 'Zone ' || zones.id)
          ELSE TRIM(excluded.name)
        END,
        thresholdHumidity = COALESCE(excluded.thresholdHumidity, zones.thresholdHumidity, 30),
        thresholdgaz = COALESCE(excluded.thresholdgaz, zones.thresholdgaz, 50),
        thresholdLight = COALESCE(excluded.thresholdLight, zones.thresholdLight, 200),
        thresholdTemperature = COALESCE(excluded.thresholdTemperature, zones.thresholdTemperature, 25),
        ev_mode = COALESCE(excluded.ev_mode, zones.ev_mode, 'AUTO'),
        use_hum = COALESCE(excluded.use_hum, zones.use_hum, 1),
        use_temp = COALESCE(excluded.use_temp, zones.use_temp, 1),
        use_gaz = COALESCE(excluded.use_gaz, zones.use_gaz, 1),
        use_light = COALESCE(excluded.use_light, zones.use_light, 1),
        use_ev = COALESCE(excluded.use_ev, zones.use_ev, 1)
    `);

    incoming.forEach((zone, index) => {
      const zoneIdRaw = getZoneId(zone, index);
      const zoneId = zoneIdRaw != null ? Math.trunc(Number(zoneIdRaw)) : null;
      if (!zoneId || !Number.isFinite(zoneId)) return;

      const zoneName = sanitizeIncomingZoneName(getZoneNameFromAnyShape(zone)) || normalizeZoneName(null, zoneId);
      if (zoneName) {
        setMobileNameGuard(zoneId, zoneName);
      }
      const { thresholdHumidity, thresholdgaz, thresholdLight, thresholdTemperature } = getThresholdsFromAnyShape(zone || {});
      const { use_hum, use_temp, use_gaz, use_light, use_ev } = getZoneUsageFlagsFromAnyShape(zone || {});
      const evMode = parseEvModeOrNull(pickFirst(zone || {}, ['mode', 'ev_mode', 'mode_ev', 'mode_status']));

      stmt.run([
        zoneId,
        zoneName,
        thresholdHumidity ?? 30,
        thresholdgaz ?? 50,
        thresholdLight ?? 200,
        thresholdTemperature ?? 25,
        evMode || 'AUTO',
        use_hum ?? 1,
        use_temp ?? 1,
        use_gaz ?? 1,
        use_light ?? 1,
        use_ev ?? 1
      ]);
    });

    stmt.finalize((finalErr) => {
      if (finalErr) return res.status(500).json({ error: finalErr.message });

      getAllZoneConfigs((newErr, newZoneConfig) => {
        if (newErr) return res.status(500).json({ error: newErr.message });

        // 1) Keep LabVIEW command pipeline working: enqueue NEW command payload.
        queueCommandWithZoneConfig({
          zone: 0,
          valve: 0,
          mode: 'SYNC_ZONE_CONFIG',
          eventType: 'SENSOR_CONFIG_CHANGE',
          oldZoneConfig,
          newZoneConfig,
          source: 'MOBILE'
        }, (queueErr) => {
          if (queueErr) return res.status(500).json({ error: queueErr.message });

          // 2) Keep user-facing history readable with per-zone diff events.
          queueZoneConfigDiffEvents({
            oldZoneConfig,
            newZoneConfig,
            source: 'MOBILE'
          }, (diffErr) => {
            if (diffErr) return res.status(500).json({ error: diffErr.message });

            db.all(`SELECT * FROM zones ORDER BY id ASC`, (zonesErr, zones) => {
              if (zonesErr) return res.status(500).json({ error: zonesErr.message });
              io.emit('zones-update', zones || []);
              emitZoneConfigUpdate();
              res.json({
                status: 'Zone config synced',
                zone_config: newZoneConfig || []
              });
            });
          });
        });
      });
    });
  });
});
// =======================
// HISTORIQUE PAGINATION PRO
// =======================


// =======================
// HISTORIQUE PAGINATION PRO
// =======================

const parsePositiveInt = (value, fallback) => {
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
};

const parseNonNegativeInt = (value, fallback) => {
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : fallback;
};

const parseBooleanQuery = (value, fallback = false) => {
  if (value === undefined || value === null) return fallback;
  const normalized = String(value).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  return fallback;
};

const parseIsoDateOrNull = (value) => {
  if (typeof value !== 'string' || !value.trim()) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return date.toISOString();
};

const parseConfigArrayForHistory = (raw) => {
  return parseJsonArray(raw)
    .map((zone) => normalizeConfigZoneForDiff(zone))
    .filter(Boolean);
};

const resolveSensorConfigZoneName = (oldConfigRaw, newConfigRaw) => {
  const oldZones = parseConfigArrayForHistory(oldConfigRaw);
  const newZones = parseConfigArrayForHistory(newConfigRaw);
  if (!newZones.length) return null;

  const oldById = new Map(oldZones.map((zone) => [zone.id, zone]));
  const changedZones = [];

  newZones.forEach((nextZone) => {
    const prevZone = oldById.get(nextZone.id);
    if (!prevZone) return;

    const changed =
      (prevZone.name || '').trim() !== (nextZone.name || '').trim() ||
      prevZone.ev_mode !== nextZone.ev_mode ||
      !sameNumberOrNull(prevZone.thresholdHumidity, nextZone.thresholdHumidity) ||
      !sameNumberOrNull(prevZone.thresholdgaz, nextZone.thresholdgaz) ||
      !sameNumberOrNull(prevZone.thresholdLight, nextZone.thresholdLight) ||
      !sameNumberOrNull(prevZone.thresholdTemperature, nextZone.thresholdTemperature) ||
      !sameNumberOrNull(prevZone.use_hum, nextZone.use_hum) ||
      !sameNumberOrNull(prevZone.use_temp, nextZone.use_temp) ||
      !sameNumberOrNull(prevZone.use_gaz, nextZone.use_gaz) ||
      !sameNumberOrNull(prevZone.use_light, nextZone.use_light) ||
      !sameNumberOrNull(prevZone.use_ev, nextZone.use_ev);

    if (changed) {
      changedZones.push(nextZone);
    }
  });

  if (changedZones.length === 1) {
    return changedZones[0].name || `Zone ${changedZones[0].id}`;
  }

  if (changedZones.length > 1) {
    const first = changedZones[0];
    const firstLabel = first.name || `Zone ${first.id}`;
    return `${firstLabel} (+${changedZones.length - 1})`;
  }

  if (newZones.length === 1) {
    return newZones[0].name || `Zone ${newZones[0].id}`;
  }

  return null;
};

const analyzeZoneConfigDiffForHistory = (oldConfigRaw, newConfigRaw) => {
  const oldZones = parseConfigArrayForHistory(oldConfigRaw);
  const newZones = parseConfigArrayForHistory(newConfigRaw);
  const oldById = new Map(oldZones.map((zone) => [zone.id, zone]));

  const changedZones = [];

  newZones.forEach((nextZone) => {
    const prevZone = oldById.get(nextZone.id);
    if (!prevZone) return;

    const nameChanged = (prevZone.name || '').trim() !== (nextZone.name || '').trim();
    const modeChanged = prevZone.ev_mode !== nextZone.ev_mode;
    const thresholdsChanged =
      !sameNumberOrNull(prevZone.thresholdHumidity, nextZone.thresholdHumidity) ||
      !sameNumberOrNull(prevZone.thresholdgaz, nextZone.thresholdgaz) ||
      !sameNumberOrNull(prevZone.thresholdLight, nextZone.thresholdLight) ||
      !sameNumberOrNull(prevZone.thresholdTemperature, nextZone.thresholdTemperature);
    const sensorsChanged =
      !sameNumberOrNull(prevZone.use_hum, nextZone.use_hum) ||
      !sameNumberOrNull(prevZone.use_temp, nextZone.use_temp) ||
      !sameNumberOrNull(prevZone.use_gaz, nextZone.use_gaz) ||
      !sameNumberOrNull(prevZone.use_light, nextZone.use_light) ||
      !sameNumberOrNull(prevZone.use_ev, nextZone.use_ev);

    if (!(nameChanged || modeChanged || thresholdsChanged || sensorsChanged)) return;

    changedZones.push({
      id: nextZone.id,
      name: nextZone.name || `Zone ${nextZone.id}`,
      nameChanged,
      modeChanged,
      thresholdsChanged,
      sensorsChanged
    });
  });

  return {
    changedZones,
    hasSensorChanges: changedZones.some((zone) => zone.sensorsChanged),
    onlyNameChanges:
      changedZones.length > 0 &&
      changedZones.every(
        (zone) =>
          zone.nameChanged &&
          !zone.modeChanged &&
          !zone.thresholdsChanged &&
          !zone.sensorsChanged
      )
  };
};


// =======================
// HISTORIQUE PAGINATION PRO (ROUTE)
// =======================

// =======================
// ROUTE HISTORIQUE PAGINATION PRO (corrigée)
// =======================
const handleHistoryRequest = (req, res) => {
  const mode = normalizeHistoryMode(req.query.mode);
  const limit = Math.min(parsePositiveInt(req.query.limit, 50), 200);
  const page = parsePositiveInt(req.query.page, 1);
  const offset = parseNonNegativeInt(req.query.offset, (page - 1) * limit);
  const includeAlerts = parseBooleanQuery(req.query.include_alerts, true);
  const searchQuery = (req.query.q ?? '').toString().trim();
  const zoneId = toNullableNumber(req.query.zone_id);
  const dateFrom = parseIsoDateOrNull(req.query.date_from);
  const dateTo = parseIsoDateOrNull(req.query.date_to);

  const wherePeriodic = [];
  const whereCommandEvents = [];
  const whereAlertEvents = [];
  const paramsPeriodic = [];
  const paramsCommandEvents = [];
  const paramsAlertEvents = [];

  if (zoneId != null) {
    wherePeriodic.push('zp.zone_id = ?');
    whereCommandEvents.push('c.zone = ?');
    whereAlertEvents.push('za.zone_id = ?');
    paramsPeriodic.push(zoneId);
    paramsCommandEvents.push(zoneId);
    paramsAlertEvents.push(zoneId);
  }

  if (dateFrom) {
    wherePeriodic.push('zp.created_at >= ?');
    whereCommandEvents.push('c.created_at >= ?');
    whereAlertEvents.push('za.created_at >= ?');
    paramsPeriodic.push(dateFrom);
    paramsCommandEvents.push(dateFrom);
    paramsAlertEvents.push(dateFrom);
  }

  if (dateTo) {
    wherePeriodic.push('zp.created_at <= ?');
    whereCommandEvents.push('c.created_at <= ?');
    whereAlertEvents.push('za.created_at <= ?');
    paramsPeriodic.push(dateTo);
    paramsCommandEvents.push(dateTo);
    paramsAlertEvents.push(dateTo);
  }

  if (searchQuery) {
    const likePattern = `%${searchQuery}%`;

    wherePeriodic.push(`(
      COALESCE(z.name, 'Zone ' || zp.zone_id) LIKE ? OR
      COALESCE(zp.ev_mode, '') LIKE ?
    )`);
    paramsPeriodic.push(likePattern, likePattern);

    whereCommandEvents.push(`(
      COALESCE(z.name, 'Zone ' || c.zone) LIKE ? OR
      COALESCE(c.mode, '') LIKE ? OR
      COALESCE(c.status, '') LIKE ?
    )`);
    paramsCommandEvents.push(likePattern, likePattern, likePattern);

    whereAlertEvents.push(`(
      COALESCE(za.zone_name, z.name, 'Zone ' || za.zone_id) LIKE ? OR
      COALESCE(za.message, '') LIKE ? OR
      COALESCE(za.level, '') LIKE ? OR
      COALESCE(za.source, '') LIKE ?
    )`);
    paramsAlertEvents.push(likePattern, likePattern, likePattern, likePattern);
  }

  const whereClausePeriodic = wherePeriodic.length ? `WHERE ${wherePeriodic.join(' AND ')}` : '';
  const whereClauseCommandEvents = whereCommandEvents.length
    ? `WHERE ${whereCommandEvents.join(' AND ')}`
    : '';
  const whereClauseAlertEvents = whereAlertEvents.length
    ? `WHERE ${whereAlertEvents.join(' AND ')}`
    : '';

  const commandEventTypeExpr = `
    COALESCE(
      NULLIF(TRIM(c.event_type), ''),
      CASE
        WHEN UPPER(COALESCE(TRIM(c.mode), '')) = 'UPDATE_THRESHOLDS' THEN 'THRESHOLD_CHANGE'
        WHEN UPPER(COALESCE(TRIM(c.mode), '')) = 'UPDATE_ZONE_NAME' THEN 'NAME_CHANGE'
        WHEN UPPER(COALESCE(TRIM(c.mode), '')) = 'SYNC_ZONE_CONFIG' THEN 'SENSOR_CONFIG_CHANGE'
        WHEN UPPER(COALESCE(TRIM(c.mode), '')) IN ('MANUAL', 'AUTO') THEN 'MODE_CHANGE'
        WHEN COALESCE(c.valve, NULL) IS NOT NULL AND COALESCE(TRIM(c.mode), '') = '' THEN 'VALVE_CHANGE'
        ELSE 'EVENT'
      END
    )
  `;

  // Hide legacy global sync placeholder rows (zone 0) from actions history.
  whereCommandEvents.push(`
    NOT (
      COALESCE(c.zone, 0) = 0
      AND ${commandEventTypeExpr} = 'SENSOR_CONFIG_CHANGE'
    )
  `);

  if (mode === 'events' || mode === 'mixed') {
    whereCommandEvents.push(`
      ${commandEventTypeExpr} IN (
        'THRESHOLD_CHANGE',
        'NAME_CHANGE',
        'VALVE_CHANGE',
        'MODE_CHANGE',
        'SENSOR_CONFIG_CHANGE'
      )
    `);
  }

  const whereClauseCommandEventsFinal = whereCommandEvents.length
    ? `WHERE ${whereCommandEvents.join(' AND ')}`
    : '';

  const periodicQuery = `
    SELECT
      'PERIODIC' AS history_type,
      'SNAPSHOT' AS event_kind,
      zp.snapshot_batch_id AS snapshot_batch_id,
      zp.id AS id,
      zp.created_at AS created_at,
      zp.created_at AS datetime,
      zp.zone_id AS zone_id,
      COALESCE(z.name, 'Zone ' || zp.zone_id) AS zone_name,
      COALESCE(zp.humidity, 0) AS humidity,
      COALESCE(zp.temperature, 0) AS zone_temperature,
      COALESCE(zp.gaz, 0) AS gaz,
      COALESCE(zp.light, 0) AS light,
      COALESCE(z.use_hum, 1) AS use_hum,
      COALESCE(z.use_temp, 1) AS use_temp,
      COALESCE(z.use_gaz, 1) AS use_gaz,
      COALESCE(z.use_light, 1) AS use_light,
      COALESCE(z.use_ev, 1) AS use_ev,
      COALESCE(zp.valve, 0) AS valve,
      COALESCE(NULLIF(TRIM(zp.ev_mode), ''), NULLIF(TRIM(z.ev_mode), ''), 'AUTO') AS ev_mode,
      COALESCE((SELECT e.temperature FROM environment e WHERE e.created_at <= zp.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS temperature,
      COALESCE((SELECT e.humidity_air FROM environment e WHERE e.created_at <= zp.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS humidity_air,
      COALESCE((SELECT e.water_level FROM environment e WHERE e.created_at <= zp.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS water_level,
      COALESCE((SELECT e.water_ph FROM environment e WHERE e.created_at <= zp.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS water_ph,
      CASE WHEN COALESCE(zp.valve, 0) = 1 THEN 'ON' ELSE 'OFF' END AS valve_state,
      'MEASUREMENT' AS event_type,
      'Mesures capteurs' AS message,
      NULL AS level,
      'LABVIEW' AS source,
      zaa.message AS active_alert_message,
      zaa.level AS active_alert_level,
      'LABVIEW' AS active_alert_source,
      zaa.updated_at AS active_alert_updated_at,
      NULL AS alert_message,
      NULL AS alert_level,
      NULL AS alert_source,
      NULL AS alert_created_at,
      NULL AS old_zone_config,
      NULL AS new_zone_config
    FROM zones_periodic_history zp
    LEFT JOIN zones z ON z.id = zp.zone_id
    LEFT JOIN zone_active_alerts zaa ON zaa.zone_id = zp.zone_id
    ${whereClausePeriodic}
  `;

  const commandEventsQuery = `
    SELECT
      'EVENT' AS history_type,
      'COMMAND' AS event_kind,
      NULL AS snapshot_batch_id,
      c.id AS id,
      c.created_at AS created_at,
      c.created_at AS datetime,
      c.zone AS zone_id,
      COALESCE(z.name, 'Zone ' || c.zone) AS zone_name,
      COALESCE(z.humidity, 0) AS humidity,
      COALESCE(z.temperature, 0) AS zone_temperature,
      COALESCE(z.gaz, 0) AS gaz,
      COALESCE(z.light, 0) AS light,
      COALESCE(z.use_hum, 1) AS use_hum,
      COALESCE(z.use_temp, 1) AS use_temp,
      COALESCE(z.use_gaz, 1) AS use_gaz,
      COALESCE(z.use_light, 1) AS use_light,
      COALESCE(z.use_ev, 1) AS use_ev,
      COALESCE(c.valve, COALESCE(z.valve, 0)) AS valve,
      COALESCE(NULLIF(TRIM(c.mode), ''), NULLIF(TRIM(z.ev_mode), ''), 'AUTO') AS ev_mode,
      COALESCE((SELECT e.temperature FROM environment e WHERE e.created_at <= c.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS temperature,
      COALESCE((SELECT e.humidity_air FROM environment e WHERE e.created_at <= c.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS humidity_air,
      COALESCE((SELECT e.water_level FROM environment e WHERE e.created_at <= c.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS water_level,
      COALESCE((SELECT e.water_ph FROM environment e WHERE e.created_at <= c.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS water_ph,
      CASE WHEN COALESCE(c.valve, z.valve, 0) = 1 THEN 'ON' ELSE 'OFF' END AS valve_state,
      ${commandEventTypeExpr} AS event_type,
      CASE
        WHEN ${commandEventTypeExpr} = 'THRESHOLD_CHANGE' THEN 'Modification des seuils'
        WHEN ${commandEventTypeExpr} = 'NAME_CHANGE' THEN 'Modification du nom de la zone'
        WHEN ${commandEventTypeExpr} = 'VALVE_CHANGE' THEN CASE WHEN COALESCE(c.valve, 0) = 1 THEN 'Ouverture de la vanne' ELSE 'Fermeture de la vanne' END
        WHEN ${commandEventTypeExpr} = 'MODE_CHANGE' THEN CASE WHEN UPPER(COALESCE(TRIM(c.mode), 'AUTO')) = 'MANUAL' THEN 'Passage en mode manuel' ELSE 'Passage en mode auto' END
        WHEN ${commandEventTypeExpr} = 'SENSOR_CONFIG_CHANGE' THEN 'Modification de la configuration des capteurs'
        ELSE COALESCE(NULLIF(TRIM(c.mode), ''), 'Action')
      END AS message,
      NULLIF(TRIM(c.alert_level), '') AS level,
      COALESCE(NULLIF(TRIM(c.alert_source), ''), 'MOBILE') AS source,
      zaa.message AS active_alert_message,
      zaa.level AS active_alert_level,
      'LABVIEW' AS active_alert_source,
      zaa.updated_at AS active_alert_updated_at,
      COALESCE(NULLIF(TRIM(c.alert_message), ''), zaa.message) AS alert_message,
      COALESCE(NULLIF(TRIM(c.alert_level), ''), zaa.level) AS alert_level,
      COALESCE(NULLIF(TRIM(c.alert_source), ''), 'LABVIEW') AS alert_source,
      COALESCE(c.alert_created_at, zaa.updated_at) AS alert_created_at,
      c.old_zone_config AS old_zone_config,
      c.new_zone_config AS new_zone_config
    FROM commands c
    LEFT JOIN zones z ON z.id = c.zone
    LEFT JOIN zone_active_alerts zaa ON zaa.zone_id = c.zone
    ${whereClauseCommandEventsFinal}
  `;

  const alertEventsQuery = `
    SELECT
      'EVENT' AS history_type,
      'ALERT' AS event_kind,
      NULL AS snapshot_batch_id,
      za.id AS id,
      za.created_at AS created_at,
      za.created_at AS datetime,
      za.zone_id AS zone_id,
      COALESCE(NULLIF(TRIM(za.zone_name), ''), z.name, 'Zone ' || za.zone_id) AS zone_name,
      COALESCE(z.humidity, 0) AS humidity,
      COALESCE(z.temperature, 0) AS zone_temperature,
      COALESCE(z.gaz, 0) AS gaz,
      COALESCE(z.light, 0) AS light,
      COALESCE(z.use_hum, 1) AS use_hum,
      COALESCE(z.use_temp, 1) AS use_temp,
      COALESCE(z.use_gaz, 1) AS use_gaz,
      COALESCE(z.use_light, 1) AS use_light,
      COALESCE(z.use_ev, 1) AS use_ev,
      COALESCE(z.valve, 0) AS valve,
      COALESCE(NULLIF(TRIM(z.ev_mode), ''), 'AUTO') AS ev_mode,
      COALESCE((SELECT e.temperature FROM environment e WHERE e.created_at <= za.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS temperature,
      COALESCE((SELECT e.humidity_air FROM environment e WHERE e.created_at <= za.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS humidity_air,
      COALESCE((SELECT e.water_level FROM environment e WHERE e.created_at <= za.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS water_level,
      COALESCE((SELECT e.water_ph FROM environment e WHERE e.created_at <= za.created_at ORDER BY e.created_at DESC LIMIT 1), 0) AS water_ph,
      CASE WHEN COALESCE(z.valve, 0) = 1 THEN 'ON' ELSE 'OFF' END AS valve_state,
      'ALERT' AS event_type,
      za.message AS message,
      za.level AS level,
      za.source AS source,
      zaa.message AS active_alert_message,
      zaa.level AS active_alert_level,
      'LABVIEW' AS active_alert_source,
      zaa.updated_at AS active_alert_updated_at,
      za.message AS alert_message,
      za.level AS alert_level,
      za.source AS alert_source,
      za.created_at AS alert_created_at,
      NULL AS old_zone_config,
      NULL AS new_zone_config
    FROM zone_alerts za
    LEFT JOIN zones z ON z.id = za.zone_id
    LEFT JOIN zone_active_alerts zaa ON zaa.zone_id = za.zone_id
    ${whereClauseAlertEvents}
  `;

  const eventsCoreQuery = includeAlerts
    ? `${commandEventsQuery} UNION ALL ${alertEventsQuery}`
    : commandEventsQuery;

  let dataQuery = '';
  let dataParams = [];

  if (mode === 'periodic') {
    dataQuery = `${periodicQuery} ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?`;
    dataParams = [...paramsPeriodic, limit, offset];
  } else if (mode === 'events') {
    dataQuery = `SELECT * FROM ( ${eventsCoreQuery} ) ev ORDER BY ev.created_at DESC, ev.id DESC LIMIT ? OFFSET ?`;
    dataParams = includeAlerts
      ? [...paramsCommandEvents, ...paramsAlertEvents, limit, offset]
      : [...paramsCommandEvents, limit, offset];
  } else {
    const mixedQuery = `${eventsCoreQuery} UNION ALL ${periodicQuery}`;
    dataQuery = `SELECT * FROM ( ${mixedQuery} ) all_rows ORDER BY all_rows.created_at DESC, all_rows.id DESC LIMIT ? OFFSET ?`;
    dataParams = includeAlerts
      ? [...paramsCommandEvents, ...paramsAlertEvents, ...paramsPeriodic, limit, offset]
      : [...paramsCommandEvents, ...paramsPeriodic, limit, offset];
  }

  db.all(dataQuery, dataParams, (dataErr, rows) => {
    if (dataErr) {
      return res.status(500).json({ error: dataErr.message });
    }

    let countQuery = '';
    let countParams = [];

    if (mode === 'periodic') {
      countQuery = `SELECT COUNT(*) AS total FROM zones_periodic_history zp LEFT JOIN zones z ON z.id = zp.zone_id ${whereClausePeriodic}`;
      countParams = paramsPeriodic;
    } else if (mode === 'events') {
      countQuery = `SELECT COUNT(*) AS total FROM ( ${eventsCoreQuery} ) ev`;
      countParams = includeAlerts
        ? [...paramsCommandEvents, ...paramsAlertEvents]
        : paramsCommandEvents;
    } else {
      const mixedCountCore = `${eventsCoreQuery} UNION ALL ${periodicQuery}`;
      countQuery = `SELECT COUNT(*) AS total FROM ( ${mixedCountCore} ) all_rows`;
      countParams = includeAlerts
        ? [...paramsCommandEvents, ...paramsAlertEvents, ...paramsPeriodic]
        : [...paramsCommandEvents, ...paramsPeriodic];
    }

    db.get(countQuery, countParams, (countErr, countRow) => {
      if (countErr) {
        return res.status(500).json({ error: countErr.message });
      }
      const total = Number.parseInt(countRow?.total, 10) || 0;
      const totalPages = total > 0 ? Math.ceil(total / limit) : 0;
      const items = (rows || []).map((row) => {
        const eventType = (row.event_type || row.event_kind || row.history_type || '').toString().toUpperCase();
        const rowZoneName = (row.zone_name || '').toString().trim();
        const rowZoneId = toNullableNumber(row.zone_id);
        let resolvedZoneName = rowZoneName;
        let resolvedEventType = eventType;
        let resolvedMessage = row.message || null;

        const isSensorConfigEvent = eventType === 'SENSOR_CONFIG_CHANGE';
        const isZone0Label = /^zone\s*0$/i.test(rowZoneName);
        if (isSensorConfigEvent) {
          const diff = analyzeZoneConfigDiffForHistory(row.old_zone_config, row.new_zone_config);
          // Rename already has a dedicated NAME_CHANGE event; avoid duplicate noisy SENSOR_CONFIG row.
          if (diff.onlyNameChanges) return null;

          if (!diff.hasSensorChanges && diff.changedZones.length === 1) {
            const changed = diff.changedZones[0];
            if (changed.modeChanged && !changed.thresholdsChanged && !changed.nameChanged) {
              resolvedEventType = 'MODE_CHANGE';
              resolvedMessage = 'Passage en mode auto/manuel';
            } else if (changed.thresholdsChanged && !changed.modeChanged && !changed.nameChanged) {
              resolvedEventType = 'THRESHOLD_CHANGE';
              resolvedMessage = 'Modification des seuils';
            }
          }
        }

        if (isSensorConfigEvent && (rowZoneId == null || rowZoneId <= 0 || isZone0Label)) {
          resolvedZoneName =
            resolveSensorConfigZoneName(row.old_zone_config, row.new_zone_config) ||
            rowZoneName ||
            'Configuration capteurs';
        }

        const alertMessage = (row.alert_message || '').toString().trim();
        const alert = includeAlerts && alertMessage
          ? {
            message: alertMessage,
            level: (row.alert_level || 'WARNING').toString(),
            source: (row.alert_source || 'LABVIEW').toString(),
            created_at: row.alert_created_at || row.created_at
          }
          : null;

        return {
          id: row.id,
          history_type: row.history_type,
          event_kind: row.event_kind,
          event_type: resolvedEventType,
          message: resolvedMessage,
          level: row.level || null,
          source: row.source || null,
          snapshot_batch_id: row.snapshot_batch_id,
          created_at: row.created_at,
          datetime: row.datetime,
          zone_id: row.zone_id,
          zone_name: resolvedZoneName,
          humidity: row.humidity,
          zone_temperature: row.zone_temperature,
          gaz: row.gaz,
          nutrition: row.gaz,
          light: row.light,
          use_hum: row.use_hum,
          use_temp: row.use_temp,
          use_gaz: row.use_gaz,
          use_light: row.use_light,
          use_ev: row.use_ev,
          valve: row.valve,
          ev_mode: row.ev_mode,
          temperature: row.temperature,
          humidity_air: row.humidity_air,
          water_level: row.water_level,
          water_ph: row.water_ph,
          valve_state: row.valve_state,
          active_alert_message: row.active_alert_message,
          active_alert_level: row.active_alert_level,
          active_alert_source: row.active_alert_source,
          active_alert_updated_at: row.active_alert_updated_at,
          alert
        };
      }).filter(Boolean);

      res.json({
        total,
        totalPages,
        items,
        pagination: {
          page,
          limit,
          offset,
          hasMore: (offset + items.length) < total
        }
      });
    });
  });
};

app.get('/historique', handleHistoryRequest);
app.get('/history', handleHistoryRequest);
// Démarrage du serveur HTTP
const PORT = 8080;
const HOST = (process.env.HOST || '0.0.0.0').trim();

server.on('error', (error) => {
  if (error?.code === 'EADDRINUSE') {
    console.error(`Le port ${PORT} est deja utilise. Change PORT ou arretez le processus qui l'utilise.`);
    return;
  }

  if (error?.code === 'EACCES' || error?.code === 'EPERM') {
    console.error(`Impossible d'ouvrir ${HOST}:${PORT}. Verifiez les permissions, le sandbox, ou utilisez un autre HOST/PORT.`);
    return;
  }

  console.error('Server startup error:', error);
});

server.listen(PORT, HOST, () => {
  console.log(`Serveur demarre sur http://${HOST}:${PORT}`);
});
