﻿#pragma once
#include <SFML/Graphics.hpp>
#include <list>
#include "Pub_Sub.hpp"
#include "Event.hpp"


class Input : public SfEventPublisher {
public:
	
	Input();
	~Input();

	// Keep track of keys that are not released
	// Keep track of mouse up and downs in conjunction with dragging
	// Keep track of joystick buttons
	void consume_sf_events(sf::RenderWindow *window);
	void consume_vr_events();
	
	void set_flags();
	void dispatch_events();
	
private:

	void transpose_sf_events(std::list<sf::Event> event_queue);

	// Network controller class

	std::vector<sf::Keyboard::Key> held_keys;
	std::vector<sf::Mouse::Button> held_mouse_buttons;
	
	std::vector<bool> keyboard_flags;
	std::vector<bool> mouse_flags;

private:
	
	std::list<vr::Event> event_queue;

};
