create or replace function public.add_student_to_class(p_class_id text, p_student_id uuid)
returns table(student_id uuid, student_email text, student_name text, student_grade text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_teacher uuid := (select auth.uid());
  v_grade text;
begin
  if not exists (
    select 1 from public.profiles t
    where t.id = v_teacher and t.role = 'teacher'
      and exists (select 1 from jsonb_array_elements(coalesce(t.app_state->'teacherClasses', '[]'::jsonb)) c where c->>'id' = p_class_id)
  ) then
    raise exception 'No se encontró la clase del docente.';
  end if;

  if not exists (
    select 1
    from public.profiles t
    join public.profiles s on s.id = p_student_id and s.role = 'student'
    where t.id = v_teacher
      and nullif(trim(t.institution->>'department'), '') is not null
      and nullif(trim(t.institution->>'municipality'), '') is not null
      and nullif(trim(t.institution->>'name'), '') is not null
      and lower(trim(coalesce(s.institution->>'department', ''))) = lower(trim(coalesce(t.institution->>'department', '')))
      and lower(trim(coalesce(s.institution->>'municipality', ''))) = lower(trim(coalesce(t.institution->>'municipality', '')))
      and lower(trim(coalesce(s.institution->>'area', ''))) = lower(trim(coalesce(t.institution->>'area', '')))
      and (
        (nullif(trim(t.institution->>'code'), '') is not null and trim(s.institution->>'code') = trim(t.institution->>'code'))
        or (nullif(trim(t.institution->>'code'), '') is null
          and nullif(trim(s.institution->>'code'), '') is null
          and lower(trim(coalesce(s.institution->>'name', ''))) = lower(trim(coalesce(t.institution->>'name', ''))))
      )
  ) then
    raise exception 'El estudiante no pertenece a la misma institución y ubicación.';
  end if;

  insert into public.class_memberships as m (teacher_id, student_id, teacher_class_id)
  values (v_teacher, p_student_id, p_class_id)
  on conflict (teacher_id, student_id, teacher_class_id) do nothing;

  select c->>'grade' into v_grade from public.profiles t, jsonb_array_elements(coalesce(t.app_state->'teacherClasses', '[]'::jsonb)) c where t.id = v_teacher and c->>'id' = p_class_id limit 1;
  if v_grade in ('Primero','Segundo','Tercero','Cuarto','Quinto') then
    update public.profiles s set grade = v_grade where s.id = p_student_id and nullif(trim(coalesce(s.grade,'')),'') is null;
  end if;

  return query select s.id, s.email, s.name, s.grade from public.profiles s where s.id = p_student_id;
end;
$$;
grant execute on function public.add_student_to_class(text, uuid) to authenticated;
