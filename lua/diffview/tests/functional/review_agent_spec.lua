local helpers = require("diffview.tests.helpers")

local eq = helpers.eq

describe("diffview.comments.agent", function()
  local agent = require("diffview.comments.agent")
  local store = require("diffview.comments.store")

  local function code_of(fn)
    local ok, err = pcall(fn)
    assert(not ok, "expected a failure")
    return err.code
  end

  local function seed()
    local doc = store.empty_doc()
    agent.apply_ops(doc, {
      { op = "add_thread", anchor = { path = "f.lua", line = 3, snippet = "x" }, body = "AI note" },
    })
    return doc
  end

  it("mints ids, authors as claude, and fills anchor defaults", function()
    local doc = seed()
    local t = doc.threads[1]
    eq("open", t.status)
    eq("claude", t.comments[1].author)
    eq({ path = "f.lua", side = "b", rev = "WORKING", line = 3, end_line = 3, snippet = "x" }, t.anchor)
    assert(t.id:match("^t%-") and t.comments[1].id:match("^c%-"))
  end)

  it("never lets the AI resolve a thread", function()
    local doc = seed()
    eq(2, code_of(function()
      agent.apply_ops(doc, { { op = "set_status", thread_id = doc.threads[1].id, status = "resolved" } })
    end))
    agent.apply_ops(doc, { { op = "set_status", thread_id = doc.threads[1].id, status = "applied" } })
    eq("applied", doc.threads[1].status)
  end)

  it("refuses to edit anyone else's comment", function()
    local doc = seed()
    local t = doc.threads[1]
    t.comments[#t.comments + 1] = { id = "c-human", author = "eyal", ts = store.now(), body = "mine" }
    eq(2, code_of(function()
      agent.apply_ops(doc, { { op = "edit_comment", comment_id = "c-human", body = "x" } })
    end))
    eq("mine", t.comments[2].body)
  end)

  it("rejects malformed ops", function()
    local doc = seed()
    eq(1, code_of(function() agent.apply_ops(doc, { { op = "add_comment", thread_id = "t-nope", body = "x" } }) end))
    eq(1, code_of(function()
      agent.apply_ops(doc, { { op = "add_thread", anchor = { path = "f", line = 0, snippet = "" }, body = "x" } })
    end))
    eq(1, code_of(function()
      agent.apply_ops(doc, { { op = "add_thread", anchor = { path = "f", line = 1 }, body = "x" } })
    end))
    eq(1, code_of(function() agent.apply_ops(doc, { { op = "bogus" } }) end))
  end)

  it("queues only open threads where the human spoke last", function()
    eq(false, store.awaiting_ai({ status = "open", comments = { { author = "claude" } } }))
    eq(true, store.awaiting_ai({ status = "open", comments = { { author = "claude" }, { author = "eyal" } } }))
    eq(true, store.awaiting_ai({ status = "open", comments = {} }))
    eq(false, store.awaiting_ai({ status = "resolved", comments = { { author = "eyal" } } }))
    eq(false, store.awaiting_ai("junk"))
  end)
end)
