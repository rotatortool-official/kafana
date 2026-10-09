/* ==================================================================
   KAFANA LEDGER

   Every order, status change and closed bill is an EVENT appended to
   one list. Nothing is ever edited or deleted: there is no function
   for it. The tables, bills and reports are all worked out by reading
   that list from the top.

   Each event carries a seal made from its own content and the seal of
   the event before it. Change any old event and every seal after it
   stops matching, so the staff screen shows exactly where the history
   was touched.

   DEMO STORAGE: this version keeps the list in the browser
   (localStorage), so the menu and the staff screen must be open in the
   same browser — two tabs on one laptop. The production version keeps
   the same list on a server, which adds the clock, the prices and the
   rules below, so a phone cannot get around them. Only this file
   changes between the two.
   ================================================================== */
(function (global) {
  'use strict';

  const KEY = 'kafana.ledger.v1';
  const TABLES = 20;
  const MAX_QTY = 50;

  // ---- SEAL ----
  // cyrb53: fast and synchronous. It shows tampering in the demo; the
  // server version would use SHA-256 and keep the list where a phone
  // cannot write to it at all.
  function seal(str) {
    let h1 = 0xdeadbeef, h2 = 0x41c6ce57;
    for (let i = 0; i < str.length; i++) {
      const ch = str.charCodeAt(i);
      h1 = Math.imul(h1 ^ ch, 2654435761);
      h2 = Math.imul(h2 ^ ch, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return (h2 >>> 0).toString(16).padStart(8, '0') + (h1 >>> 0).toString(16).padStart(8, '0');
  }
  function sealOf(ev) {
    return seal(JSON.stringify([ev.seq, ev.at, ev.type, ev.data, ev.prev]));
  }

  // ---- STORAGE ----
  function load() {
    try {
      const raw = localStorage.getItem(KEY);
      return raw ? JSON.parse(raw) : [];
    } catch (e) { return []; }
  }
  function store(events) {
    localStorage.setItem(KEY, JSON.stringify(events));
  }

  // ---- STATE: replay the list ----
  const STATUS_ORDER = ['new', 'accepted', 'served'];

  function replay(events) {
    const bills = {};          // billId -> bill
    const openByTable = {};    // table -> billId
    const rounds = {};         // round seq -> round
    let billCount = 0;

    events.forEach(function (ev) {
      const d = ev.data;
      if (ev.type === 'round') {
        let billId = openByTable[d.table];
        if (!billId) {
          billId = ev.seq;
          openByTable[d.table] = billId;
          bills[billId] = {
            id: billId, table: d.table, openedAt: ev.at, rounds: [],
            total: 0, status: 'open', requestedAt: null
          };
        }
        const round = {
          seq: ev.seq, billId: billId, table: d.table, at: ev.at,
          items: d.items, total: d.total, by: d.by, waiter: d.waiter || null,
          status: 'new', statusAt: ev.at, statusBy: null
        };
        rounds[ev.seq] = round;
        bills[billId].rounds.push(round);
        bills[billId].total += d.total;
        bills[billId].lastAt = ev.at;
      } else if (ev.type === 'status') {
        const r = rounds[d.round];
        if (r) { r.status = d.status; r.statusAt = ev.at; r.statusBy = d.waiter; }
      } else if (ev.type === 'bill_request') {
        const b = bills[d.bill];
        if (b && b.status === 'open') b.requestedAt = ev.at;
      } else if (ev.type === 'close') {
        const b = bills[d.bill];
        if (b && b.status === 'open') {
          billCount++;
          b.status = 'closed';
          b.closedAt = ev.at;
          b.closedBy = d.waiter;
          b.method = d.method;
          b.number = d.number;
          delete openByTable[b.table];
        }
      }
    });
    return { bills: bills, openByTable: openByTable, rounds: rounds, billCount: billCount };
  }

  // ---- RULES ----
  // What the server would refuse. The demo refuses the same things here.
  function check(type, data, state) {
    if (type === 'round') {
      const t = Number(data.table);
      if (!Number.isInteger(t) || t < 1 || t > TABLES) throw new Error('Непозната маса');
      if (!Array.isArray(data.items) || !data.items.length) throw new Error('Празна нарачка');
      let total = 0;
      data.items.forEach(function (it) {
        if (!it.name || !(it.price > 0)) throw new Error('Ставка без цена');
        if (!Number.isInteger(it.qty) || it.qty < 1 || it.qty > MAX_QTY) throw new Error('Неважечка количина');
        total += it.price * it.qty;
      });
      data.total = Math.round(total * 100) / 100;   // the total is never taken from the caller
      if (data.by === 'waiter' && !data.waiter) throw new Error('Изберете келнер');
    } else if (type === 'status') {
      const r = state.rounds[data.round];
      if (!r) throw new Error('Непозната нарачка');
      if (state.bills[r.billId].status !== 'open') throw new Error('Сметката е затворена');
      if (STATUS_ORDER.indexOf(data.status) <= STATUS_ORDER.indexOf(r.status)) {
        throw new Error('Статусот оди само напред');
      }
      if (!data.waiter) throw new Error('Изберете келнер');
    } else if (type === 'bill_request') {
      const b = state.bills[data.bill];
      if (!b || b.status !== 'open') throw new Error('Нема отворена сметка');
    } else if (type === 'close') {
      const b = state.bills[data.bill];
      if (!b) throw new Error('Непозната сметка');
      if (b.status !== 'open') throw new Error('Сметката е веќе затворена');
      if (!data.waiter) throw new Error('Изберете келнер');
      if (data.method !== 'cash' && data.method !== 'card') throw new Error('Изберете начин на плаќање');
      data.total = b.total;
      data.number = state.billCount + 1;
    } else {
      throw new Error('Непознат настан');
    }
  }

  // ---- PUBLIC ----
  const listeners = [];

  const Ledger = {
    TABLES: TABLES,

    events: load,

    state: function () { return replay(load()); },

    /* The only way anything gets written. Returns the new event. */
    append: function (type, data) {
      const events = load();
      const state = replay(events);
      data = JSON.parse(JSON.stringify(data));
      check(type, data, state);
      const last = events[events.length - 1];
      const ev = {
        seq: last ? last.seq + 1 : 1,
        at: new Date().toISOString(),
        type: type,
        data: data,
        prev: last ? last.hash : '0'
      };
      ev.hash = sealOf(ev);
      events.push(ev);
      store(events);
      listeners.forEach(function (fn) { fn(); });
      return ev;
    },

    /* First event whose seal no longer matches, or null if all is intact. */
    verify: function () {
      const events = load();
      let prev = '0';
      for (let i = 0; i < events.length; i++) {
        const ev = events[i];
        if (ev.prev !== prev || ev.hash !== sealOf(ev) || ev.seq !== i + 1) return ev.seq || i + 1;
        prev = ev.hash;
      }
      return null;
    },

    onChange: function (fn) {
      listeners.push(fn);
      global.addEventListener('storage', function (e) { if (e.key === KEY) fn(); });
    },

    /* Demo only: wipes the whole list so the showcase can start over.
       The production ledger has no such switch. */
    resetDemo: function () {
      localStorage.removeItem(KEY);
      listeners.forEach(function (fn) { fn(); });
    }
  };

  global.Ledger = Ledger;
})(window);
