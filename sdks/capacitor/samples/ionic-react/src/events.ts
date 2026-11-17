import { useSyncExternalStore } from 'react';

// What the SDK reported, newest first, worded as in the other sandbox demos.
let lines: string[] = [];
const subscribers = new Set<() => void>();

export function addEvent(line: string) {
  lines = [line, ...lines];
  subscribers.forEach((notify) => notify());
}

// At module scope: a new function on each render would make React subscribe again every time.
function subscribe(notify: () => void) {
  subscribers.add(notify);
  return () => {
    subscribers.delete(notify);
  };
}

function snapshot() {
  return lines;
}

export function useEvents(): string[] {
  return useSyncExternalStore(subscribe, snapshot);
}
