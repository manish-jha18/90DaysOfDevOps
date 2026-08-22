INSERT INTO projects (name, description)
SELECT 'DevBoard', 'The 90 days of DevOps challenge board'
WHERE NOT EXISTS (SELECT 1 FROM projects);

INSERT INTO tasks (title, project_id, status)
SELECT 'Set up CI pipeline', 1, 'in_progress'
WHERE NOT EXISTS (SELECT 1 FROM tasks);
