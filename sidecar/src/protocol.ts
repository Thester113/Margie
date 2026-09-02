// Shared wire/paths for the Margie brain daemon and its clients.
// NDJSON over a unix socket:
//   client → daemon  {"id":n,"text":"...","source":"app"|"cli"}   one turn
//                    {"op":"hello"|"status"|"ping"|"stop", ...}   control
//   daemon → client  {"id":n,"text":"..."}                        final reply
//                    {"id":n,"event":"tool"|"held","text":"..."}  progress (requester only)
//                    {"event":"notice","text":"..."}              unsolicited broadcast
//                    {"op":"status"|"pong"|"stopping", ...}       control answers
import { homedir } from "node:os";

export const MARGIE_DIR = `${process.env.HOME || homedir()}/.margie`;
export const SOCK = process.env.MARGIE_SOCK || `${MARGIE_DIR}/brain.sock`;
export const LOCK = `${MARGIE_DIR}/brain.lock`;
export const DAEMON_LOG = `${MARGIE_DIR}/daemon.log`;

export interface WireIn {
  id?: number;
  text?: string;
  source?: string;
  op?: "hello" | "status" | "ping" | "stop";
  build?: number;
}
export interface WireOut {
  id?: number;
  text?: string;
  event?: "tool" | "result" | "thinking" | "held" | "notice";
  op?: "status" | "pong" | "stopping";
  [k: string]: unknown;
}
