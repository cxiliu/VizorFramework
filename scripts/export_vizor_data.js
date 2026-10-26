// Runs INSIDE the vizor-mongo container under mongosh, driven by export_vizor_data.ps1, so the
// host needs neither Python nor a MongoDB driver. Writes one folder per session under OUT_DIR:
//
//   <start UTC>_<participant>_<session id tail>/
//     session.json            the session document plus per-topic message counts
//     <topic>.csv             one row per message, the ROS message flattened into columns
//     messages.jsonl          every message verbatim, for anything the CSVs flatten badly
//
// Messages logged with no session active go to a "_no_session" folder the same way.
//
// Inputs arrive as environment variables (docker exec -e) rather than --eval, so values with
// quotes in them never need escaping: OUT_DIR, and optional SESSION_ID / PARTICIPANT filters.

const fs = require('fs');
const path = require('path');

const outRoot = process.env.OUT_DIR;
const sessionFilter = process.env.SESSION_ID || '';
const participantFilter = process.env.PARTICIPANT || '';

// Filename-safe: topic names start with '/' and participant ids are free text.
function safe(s) {
    return String(s).replace(/^\/+/, '').replace(/[^A-Za-z0-9._-]+/g, '_') || 'unnamed';
}

function stamp(d) {
    // 2026-10-26T08:02:59.065Z -> 2026-10-26_080259Z
    return d.toISOString().replace(/\.\d+Z$/, 'Z').replace('T', '_').replace(/:/g, '');
}

// BSON values mongosh hands back as objects. Integers of 2^31 and up are stored as int64 and come
// back as Long {high, low, unsigned}, so without this a large ROS integer would be split into
// three meaningless columns.
function isScalar(value) {
    return value === null || typeof value !== 'object' || value instanceof Date || value._bsontype !== undefined;
}

// Long -> number when exact, else its decimal string; Decimal128 / ObjectId -> string.
function scalarValue(value) {
    if (value === null || typeof value !== 'object' || value instanceof Date) return value;
    if (value._bsontype === 'Long') {
        const n = value.toNumber();
        return Number.isSafeInteger(n) ? n : value.toString();
    }
    return value.toString();
}

// geometry_msgs/Pose -> position.x, position.y, ..., orientation.w; std_msgs/String -> data.
// Arrays flatten by index (points.0.x), which is fine for the small fixed-size arrays ROS uses.
function flatten(value, prefix, out) {
    if (!isScalar(value)) {
        for (const k of Object.keys(value)) flatten(value[k], prefix ? prefix + '.' + k : k, out);
    } else {
        out[prefix || 'value'] = scalarValue(value);
    }
    return out;
}

function csvCell(v) {
    if (v === null || v === undefined) return '';
    const s = v instanceof Date ? v.toISOString() : String(v);
    return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

// A JSON-ready copy: the BSON scalars above become numbers or strings, Dates become ISO strings.
function toPlain(value) {
    if (isScalar(value)) {
        const v = scalarValue(value);
        return v instanceof Date ? v.toISOString() : v;
    }
    if (Array.isArray(value)) return value.map(toPlain);
    const out = {};
    for (const k of Object.keys(value)) out[k] = toPlain(value[k]);
    return out;
}

function exportMessages(dir, messageQuery) {
    fs.mkdirSync(dir, { recursive: true });
    const topics = db.topic_messages.distinct('topic_name', messageQuery).sort();
    const counts = {};

    for (const topic of topics) {
        const q = Object.assign({}, messageQuery, { topic_name: topic });

        // Two passes: the first collects the union of fields, so a message that omits an optional
        // field still lands in the right column instead of shifting the row.
        const fields = [];
        const seen = new Set();
        db.topic_messages.find(q, { data: 1 }).forEach(m => {
            for (const k of Object.keys(flatten(m.data, '', {}))) {
                if (!seen.has(k)) { seen.add(k); fields.push(k); }
            }
        });

        const header = ['timestamp', 'unix_time', 'message_type', 'session_id', 'participant_id'].concat(fields);
        const file = path.join(dir, safe(topic) + '.csv');
        fs.writeFileSync(file, header.join(',') + '\n');

        let buf = [];
        let n = 0;
        db.topic_messages.find(q).sort({ timestamp: 1 }).forEach(m => {
            const flat = flatten(m.data, '', {});
            const row = [m.timestamp, m.timestamp.getTime() / 1000, m.message_type, m.session_id, m.participant_id]
                .concat(fields.map(f => flat[f]));
            buf.push(row.map(csvCell).join(','));
            n++;
            if (buf.length >= 5000) { fs.appendFileSync(file, buf.join('\n') + '\n'); buf = []; }
        });
        if (buf.length) fs.appendFileSync(file, buf.join('\n') + '\n');
        counts[topic] = n;
    }

    const jsonl = path.join(dir, 'messages.jsonl');
    fs.writeFileSync(jsonl, '');
    let buf = [];
    db.topic_messages.find(messageQuery).sort({ timestamp: 1 }).forEach(m => {
        buf.push(JSON.stringify(toPlain(m)));
        if (buf.length >= 5000) { fs.appendFileSync(jsonl, buf.join('\n') + '\n'); buf = []; }
    });
    if (buf.length) fs.appendFileSync(jsonl, buf.join('\n') + '\n');

    return counts;
}

const sessionQuery = {};
if (sessionFilter) sessionQuery._id = ObjectId(sessionFilter);
if (participantFilter) sessionQuery.participant_id = participantFilter;

let exported = 0;
db.sessions.find(sessionQuery).sort({ start_time: 1 }).forEach(s => {
    const id = s._id.toHexString();
    const name = [stamp(s.start_time), safe(s.participant_id), id.slice(-6)].join('_');
    const counts = exportMessages(path.join(outRoot, name), { session_id: id });

    const meta = Object.assign(toPlain(s), {
        topic_counts: counts,
        in_progress: !s.end_time,
        exported_at: new Date().toISOString(),
    });
    fs.writeFileSync(path.join(outRoot, name, 'session.json'), JSON.stringify(meta, null, 2) + '\n');

    const summary = Object.keys(counts).map(t => t + '=' + counts[t]).join(', ') || 'no messages';
    print(name + (s.end_time ? '' : '  [still in progress]') + '  ' + summary);
    exported++;
});

// Only when no filter was given: a filtered export asked for specific sessions, not strays.
if (!sessionFilter && !participantFilter) {
    const stray = { session_id: null };
    if (db.topic_messages.countDocuments(stray) > 0) {
        const counts = exportMessages(path.join(outRoot, '_no_session'), stray);
        print('_no_session  ' + Object.keys(counts).map(t => t + '=' + counts[t]).join(', '));
    }
}

if (exported === 0) print('No matching sessions.');
