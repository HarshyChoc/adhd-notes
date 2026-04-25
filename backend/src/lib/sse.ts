import { EventEmitter } from "node:events";

type EventPayload = {
  sequence: number;
  type: string;
  payload: unknown;
};

class SseHub {
  private readonly emitter = new EventEmitter();

  publish(userId: string, event: EventPayload) {
    this.emitter.emit(this.channel(userId), event);
  }

  subscribe(userId: string, listener: (event: EventPayload) => void): () => void {
    const channel = this.channel(userId);
    this.emitter.on(channel, listener);
    return () => {
      this.emitter.off(channel, listener);
    };
  }

  private channel(userId: string) {
    return `user:${userId}`;
  }
}

export const sseHub = new SseHub();
