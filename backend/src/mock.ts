export type MockTaskListDescriptor = {
  id: string;
  title: string;
};

export const MOCK_TASK_LISTS: MockTaskListDescriptor[] = [
  { id: "mock-inbox", title: "Mock Inbox" },
  { id: "mock-personal", title: "Mock Personal" },
  { id: "mock-work", title: "Mock Work" },
];
