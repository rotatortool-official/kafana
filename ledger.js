/* ==================================================================
   KAFANA LEDGER — client

   Every order, status change and closed bill is an EVENT in one list
   on the server (Supabase project "kafana"). Nothing in it is ever
   edited or deleted: the database refuses it, for everyone. The tables,
   bills and reports are all worked out here by reading that list from
   the top.

   The server applies the rules, not this file: it takes prices from its
   own menu table, stamps the time, numbers the bills and refuses any
   change to an order once it is sent. A phone can only ask; it cannot
   decide.

   Each event carries a SHA-256 seal of its own content and the seal of
   the event before it, so any change made around the rules (straight
   in the database) shows up on the staff screen.
   ================================================================== */
(function (global) {
  'use strict';

  const URL = 'https://zrlszhpesifpuikwgxnk.supabase.co';
  const KEY = 'sb_publishable_HZV7ivm4v9ny_MSzLFWf2Q_LbhTfsp6';   // public by design
  const TABLES = 20;
  const PAGE = 1000;

  const db = global.supabase.createClient(URL, KEY);

  let cache = [];
  const listeners = [];
  function notify() { listeners.forEach(function (fn) { fn(); }); }

  // ---- LOADING ----
  // The screens only need what happened since the last test reset.
  async function loadAll() {
    const reset = await db.from('events').select('seq').eq('type', 'reset')
      .order('seq', { ascending: false }).limit(1);
    if (reset.error) throw reset.error;
    const from = reset.data.length ? reset.data[0].seq : 0;
    const out = [];
    for (let start = 0; ; start += PAGE) {
      const res = await db.from('events').select('*').gte('seq', from)
        .order('seq').range(start, start + PAGE - 1);
      if (res.error) throw res.error;
      out.push.apply(out, res.data);
      if (res.data.length < PAGE) break;
    }
    cache = out;
  }

  async function loadNew() {
    const last = cache.length ? cache[cache.length - 1].seq : 0;
    const res = await db.from('events').select('*').gt('seq', last).order('seq').limit(PAGE);
    if (res.error) return;
    if (!res.data.length) return;
    if (res.data.some(function (e) { return e.type === 'reset'; })) await loadAll();
    else cache = cache.concat(res.data);
    notify();
  }

  let pending = null;
  function refresh() {
    if (!pending) pending = loadNew().finally(function () { pending = null; });
    return pending;
  }

  // ---- STATE: replay the list ----
  function replay(events) {
    let bills = {}, openByTable = {}, rounds = {}, billCount = 0;

    function billFor(id, table, at) {
      if (!bills[id]) {
        bills[id] = {
          id: id, table: table, openedAt: at, rounds: [],
          total: 0, status: 'open', requestedAt: null, void: false
        };
      }
      if (bills[id].status === 'open') openByTable[table] = id;
      return bills[id];
    }
    // A bill whose every order was moved away or rejected frees its table.
    function settle(b) {
      if (b.status !== 'open') return;
      if (!b.rounds.length) {
        delete bills[b.id];
      } else if (!b.rounds.some(r => !r.rejected)) {
        b.void = true;
      } else {
        return;
      }
      if (openByTable[b.table] === b.id) delete openByTable[b.table];
    }

    events.forEach(function (ev) {
      const d = ev.data;
      if (ev.type === 'reset') {
        bills = {}; openByTable = {}; rounds = {}; billCount = 0;
      } else if (ev.type === 'round') {
        const bill = billFor(d.bill, d.table, ev.at);
        const round = {
          seq: ev.seq, billId: d.bill, table: d.table, at: ev.at,
          items: d.items.map(function (it) { return { name: it.name, qty: it.qty, price: Number(it.price), category: it.category }; }),
          total: Number(d.total), by: d.by, waiter: d.waiter || null,
          status: 'new', statusAt: ev.at, statusBy: null,
          rejected: null, movedFrom: null,
          log: []   // every accept, move, reject and serve, with who and when
        };
        rounds[ev.seq] = round;
        bill.rounds.push(round);
        bill.total += round.total;
        bill.lastAt = ev.at;
      } else if (ev.type === 'status') {
        const r = rounds[d.round];
        if (r) {
          r.status = d.status; r.statusAt = ev.at; r.statusBy = d.waiter;
          r.log.push({ status: d.status, at: ev.at, by: d.waiter });
        }
      } else if (ev.type === 'move') {
        const r = rounds[d.round];
        if (r) {
          const from = bills[r.billId];
          if (from) {
            from.rounds = from.rounds.filter(x => x !== r);
            from.total -= r.total;
          }
          const to = billFor(d.to_bill, d.to_table, ev.at);
          to.rounds.push(r);
          to.rounds.sort((a, b) => a.seq - b.seq);
          to.total += r.total;
          r.billId = d.to_bill;
          r.movedFrom = { table: d.from_table, at: ev.at, by: d.waiter };
          r.table = d.to_table;
          r.log.push({ status: 'moved', from: d.from_table, to: d.to_table, at: ev.at, by: d.waiter });
          if (from) settle(from);
        }
      } else if (ev.type === 'reject') {
        const r = rounds[d.round];
        if (r && !r.rejected) {
          r.rejected = { reason: d.reason, at: ev.at, by: d.waiter };
          r.log.push({ status: 'rejected', reason: d.reason, at: ev.at, by: d.waiter });
          const b = bills[r.billId];
          if (b) { b.total -= r.total; settle(b); }
        }
      } else if (ev.type === 'bill_request') {
        const b = bills[d.bill];
        if (b && b.status === 'open') b.requestedAt = b.requestedAt || ev.at;
      } else if (ev.type === 'close') {
        const b = bills[d.bill];
        if (b && b.status === 'open') {
          billCount++;
          b.status = 'closed';
          b.closedAt = ev.at;
          b.closedBy = d.waiter;
          b.method = d.method;
          b.number = d.number;
          if (openByTable[b.table] === b.id) delete openByTable[b.table];
        }
      }
    });
    return { bills: bills, openByTable: openByTable, rounds: rounds, billCount: billCount };
  }

  // ---- WRITING: always through the server's rules ----
  async function rpc(name, args) {
    const res = await db.rpc(name, args);
    if (res.error) throw new Error(res.error.message || 'Грешка при врската');
    await refresh();
    return res.data;
  }
  const items = list => list.map(it => ({ name: it.name, qty: it.qty }));   // never a price

  const Ledger = {
    TABLES: TABLES,
    db: db,

    ready: loadAll().then(notify),

    events: function () { return cache; },
    state: function () { return replay(cache); },

    guestOrder: (table, list) => rpc('guest_order', { p_table: table, p_items: items(list) }),
    requestBill: table => rpc('guest_request_bill', { p_table: table }),

    staffOrder: (table, list, waiter) => rpc('staff_order', { p_table: table, p_items: items(list), p_waiter: waiter }),
    staffStatus: (round, status, waiter) => rpc('staff_status', { p_round: round, p_status: status, p_waiter: waiter }),
    staffAccept: (round, table, waiter) => rpc('staff_accept', { p_round: round, p_table: table, p_waiter: waiter }),
    staffReject: (round, reason, waiter) => rpc('staff_reject', { p_round: round, p_reason: reason, p_waiter: waiter }),
    staffClose: (bill, method, waiter) => rpc('staff_close', { p_bill: bill, p_method: method, p_waiter: waiter }),
    resetTest: waiter => rpc('staff_reset_test', { p_waiter: waiter }).then(loadAll).then(notify),

    /* First event whose seal no longer matches, or null if all is intact. */
    verify: async function () {
      const res = await db.rpc('verify_ledger');
      if (res.error) throw new Error(res.error.message);
      return res.data;
    },

    isStaff: async function () {
      const res = await db.rpc('is_staff');
      return !res.error && res.data === true;
    },

    onChange: function (fn) { listeners.push(fn); }
  };

  // ---- LIVE ----
  // New events arrive over realtime; a slow poll and a check on return to
  // the tab cover a dropped connection or a phone that went to sleep.
  db.channel('events')
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'events' }, refresh)
    .subscribe();
  setInterval(refresh, 10000);
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') refresh();
  });

  global.Ledger = Ledger;
})(window);
