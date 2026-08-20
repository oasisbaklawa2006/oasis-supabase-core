/** @file Shared types for WhatsApp content interpretation. */

export type SourceKind =
  | "text"
  | "image"
  | "audio"
  | "video"
  | "document"
  | "packet";

export type InboundMessageRow = {
  provider_message_id: string | null;
  content: string | null;
  message_type: string | null;
  media_url: string | null;
  message_timestamp: string | null;
};

export type LoadedMessage = {
  providerMessageId: string;
  sourceText: string;
  messageType: string;
  mediaUrl: string;
  messageTimestamp: string;
};

export type RequestIds = {
  ids: string[];
  packetMode: boolean;
};

export type MediaPayload = {
  bytes: Uint8Array;
  mime: string;
};
