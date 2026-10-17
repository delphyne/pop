_addon.name = 'pop'
_addon.author = 'Brian M. Carr'
_addon.version = '0.1.0'
_addon.command = 'pop'

windower.register_event('addon command', function(...)
    windower.add_to_chat(207, 'pop: Hello, world!')
end)
