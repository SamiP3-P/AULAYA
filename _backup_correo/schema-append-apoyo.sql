

-- ===== Apoyo, actividades especiales y banco de preguntas =====
-- 1) Aviso de apoyo: si el estudiante vuelve a sacar bajo, el aviso se actualiza y vuelve a quedar sin leer.
create or replace function public.report_low_lesson_progress(
  p_lesson_key text, p_lesson_name text, p_subject_name text, p_progress integer
)
returns integer
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_student uuid := (select auth.uid());
  v_name text;
  inserted_count integer := 0;
begin
  select name into v_name from public.profiles where id = v_student and role = 'student';
  if v_name is null then raise exception 'Solo las cuentas de estudiante pueden enviar este aviso.'; end if;
  if p_progress < 0 or p_progress > 60 then raise exception 'El progreso debe estar entre 0 y 60.'; end if;
  if length(trim(coalesce(p_lesson_key, ''))) = 0 or length(trim(coalesce(p_lesson_name, ''))) = 0 then
    raise exception 'Falta identificar la lección.';
  end if;
  insert into public.teacher_notifications as n (teacher_id, student_id, teacher_class_id, lesson_key, student_name, lesson_name, subject_name, progress)
  select distinct on (m.teacher_id) m.teacher_id, v_student, m.teacher_class_id, p_lesson_key, v_name, p_lesson_name, coalesce(p_subject_name, ''), p_progress
  from public.class_memberships m
  where m.student_id = v_student
  order by m.teacher_id, m.created_at
  on conflict (teacher_id, student_id, lesson_key)
  do update set progress = excluded.progress, student_name = excluded.student_name, created_at = now(), read_at = null;
  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

-- 2) Actividades especiales: cada estudiante solo recibe las de toda la clase y las que son para él.
drop function if exists public.get_my_class_activities();
create function public.get_my_class_activities()
returns table(teacher_class_id text, teacher_name text, class_label text, activities jsonb, joined_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select membership.teacher_class_id,
    teacher.name,
    concat_ws(' ', owned_class.value->>'grade', owned_class.value->>'sectionLabel'),
    coalesce((
      select jsonb_agg(act.value)
      from jsonb_array_elements(coalesce(owned_class.value->'activities', '[]'::jsonb)) as act(value)
      where jsonb_typeof(act.value->'assignedTo') is distinct from 'array'
         or jsonb_array_length(act.value->'assignedTo') = 0
         or (act.value->'assignedTo') ? ((select auth.uid())::text)
    ), '[]'::jsonb),
    membership.created_at
  from public.class_memberships membership
  join public.profiles teacher on teacher.id = membership.teacher_id
  join lateral jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
    on owned_class.value->>'id' = membership.teacher_class_id
  where membership.student_id = (select auth.uid());
$$;
revoke all on function public.get_my_class_activities() from public, anon;
grant execute on function public.get_my_class_activities() to authenticated;

-- 3) Banco de preguntas compartido por los docentes.
create table if not exists public.question_bank (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  grade text not null,
  subject text not null,
  topic text not null,
  question text not null check (length(question) between 3 and 300),
  answers jsonb not null check (jsonb_typeof(answers) = 'array' and jsonb_array_length(answers) between 2 and 6),
  correct integer not null check (correct >= 0),
  created_at timestamptz not null default now(),
  unique (teacher_id, grade, subject, topic, question)
);
alter table public.question_bank enable row level security;
drop policy if exists "Teachers add their questions" on public.question_bank;
create policy "Teachers add their questions" on public.question_bank
  for insert to authenticated with check (
    teacher_id = (select auth.uid())
    and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher')
  );
drop policy if exists "Teachers read the shared bank" on public.question_bank;
create policy "Teachers read the shared bank" on public.question_bank
  for select to authenticated using (
    exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher')
  );
drop policy if exists "Teachers delete their questions" on public.question_bank;
create policy "Teachers delete their questions" on public.question_bank
  for delete to authenticated using (teacher_id = (select auth.uid()));
grant select, insert, delete on public.question_bank to authenticated;

create or replace function public.question_bank_summary()
returns table(grade text, subject text, topic text, total bigint, mine bigint)
language sql stable security definer set search_path = '' as $$
  select q.grade, q.subject, q.topic, count(*), count(*) filter (where q.teacher_id = (select auth.uid()))
  from public.question_bank q
  where exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher')
  group by q.grade, q.subject, q.topic
  order by q.grade, q.subject, q.topic;
$$;
revoke all on function public.question_bank_summary() from public, anon;
grant execute on function public.question_bank_summary() to authenticated;
notify pgrst, 'reload schema';


-- Reglas del almacenamiento: "objects.name" (ruta del archivo) va calificado; sin calificar se confundía con profiles.name.
drop policy if exists "Teachers upload their class videos" on storage.objects;
create policy "Teachers upload their class videos" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'class-videos' and split_part(objects.name, '/', 1) = (select auth.uid())::text
    and exists (
      select 1 from public.profiles teacher
      where teacher.id = (select auth.uid()) and teacher.role = 'teacher'
        and exists (
          select 1 from jsonb_array_elements(coalesce(teacher.app_state->'teacherClasses', '[]'::jsonb)) as owned_class(value)
          where owned_class.value->>'id' = split_part(objects.name, '/', 2)
        )
    )
  );
drop policy if exists "Class members can read their videos" on storage.objects;
create policy "Class members can read their videos" on storage.objects
  for select to authenticated using (
    bucket_id = 'class-videos' and (
      split_part(objects.name, '/', 1) = (select auth.uid())::text or exists (
        select 1 from public.class_memberships membership
        where membership.teacher_id::text = split_part(objects.name, '/', 1)
          and membership.student_id = (select auth.uid())
          and membership.teacher_class_id = split_part(objects.name, '/', 2)
      )
    )
  );
drop policy if exists "Teachers delete their class videos" on storage.objects;
create policy "Teachers delete their class videos" on storage.objects
  for delete to authenticated using (bucket_id = 'class-videos' and split_part(objects.name, '/', 1) = (select auth.uid())::text);
