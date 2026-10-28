-- CUTLINE: the "subscribe to the channel" task points to @cutline_channel.
update public.app_config set value = jsonb_set(value, '{channel}', '"cutline_channel"') where key = 'quests';
