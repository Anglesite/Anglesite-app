import { describe, it, expect } from "vitest";
import {
  nextEditID,
  postEdit,
  installReplyHandler,
  type EditMessage,
  type EditReply,
} from "../src/messages.js";

const sampleMessage: EditMessage = {
  id: "fixed-1",
  type: "anglesite:apply-edit",
  path: "/about/",
  selector: "html > body > main > p",
  op: "set-text",
  value: "Hello",
};

describe("nextEditID", () => {
  it("produces a fresh non-empty string each call", () => {
    const a = nextEditID();
    const b = nextEditID();
    expect(a).not.toEqual("");
    expect(b).not.toEqual("");
    expect(a).not.toEqual(b);
  });
});

describe("postEdit", () => {
  it("calls webkit.messageHandlers.anglesite.postMessage with the message and returns true", () => {
    const sent: unknown[] = [];
    const fakeWindow = {
      webkit: {
        messageHandlers: {
          anglesite: { postMessage: (body: unknown) => { sent.push(body); } },
        },
      },
    };
    const ok = postEdit(sampleMessage, fakeWindow);
    expect(ok).toBe(true);
    expect(sent).toEqual([sampleMessage]);
  });

  it("returns false (no throw) when the webkit bridge is missing", () => {
    expect(postEdit(sampleMessage, {})).toBe(false);
  });
});

describe("installReplyHandler", () => {
  it("dispatches to the registered handler when _handleReply is called", () => {
    type AnyWin = { anglesite?: { _handleReply?: (r: EditReply) => void } };
    const win: AnyWin = {};
    const { awaitReply } = installReplyHandler(win);

    let received: EditReply | null = null;
    awaitReply("e-1", (r) => { received = r; });

    win.anglesite?._handleReply?.({ id: "e-1", status: "applied", message: "ok" });
    expect(received).toEqual({ id: "e-1", status: "applied", message: "ok" });
  });

  it("ignores replies for unknown ids", () => {
    type AnyWin = { anglesite?: { _handleReply?: (r: EditReply) => void } };
    const win: AnyWin = {};
    installReplyHandler(win);
    expect(() => win.anglesite?._handleReply?.({ id: "never-registered", status: "failed" })).not.toThrow();
  });

  it("removes the registration after one dispatch", () => {
    type AnyWin = { anglesite?: { _handleReply?: (r: EditReply) => void } };
    const win: AnyWin = {};
    const { awaitReply } = installReplyHandler(win);

    let count = 0;
    awaitReply("e-2", () => { count += 1; });
    win.anglesite?._handleReply?.({ id: "e-2", status: "applied" });
    win.anglesite?._handleReply?.({ id: "e-2", status: "applied" });
    expect(count).toBe(1);
  });
});
