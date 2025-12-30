#!/usr/bin/env python3
"""
Validation script for Retell AI conversation flow JSON
Checks for common issues that cause import errors
"""

import json
import sys

def validate_retell_flow(filepath):
    """Validate Retell AI conversation flow JSON structure"""

    errors = []
    warnings = []

    try:
        with open(filepath, 'r') as f:
            flow = json.load(f)
    except json.JSONDecodeError as e:
        print(f"❌ JSON Syntax Error: {e}")
        return False

    # Check required root fields
    required_root_fields = ['start_node_id', 'nodes']
    for field in required_root_fields:
        if field not in flow:
            errors.append(f"Missing required root field: '{field}'")

    # Check start_node_id exists in nodes
    if 'start_node_id' in flow and 'nodes' in flow:
        node_ids = {node.get('id') for node in flow['nodes']}
        if flow['start_node_id'] not in node_ids:
            errors.append(f"start_node_id '{flow['start_node_id']}' does not exist in nodes")

    # Validate nodes
    if 'nodes' in flow:
        if not isinstance(flow['nodes'], list):
            errors.append("'nodes' must be an array")
        elif len(flow['nodes']) == 0:
            errors.append("'nodes' array cannot be empty")
        else:
            for idx, node in enumerate(flow['nodes']):
                node_id = node.get('id', f'<node_index_{idx}>')

                # Check required node fields
                if 'id' not in node:
                    errors.append(f"Node at index {idx} missing 'id' field")

                if 'type' not in node:
                    errors.append(f"Node '{node_id}' missing 'type' field")
                else:
                    node_type = node['type']

                    # Validate based on type
                    if node_type == 'conversation':
                        if 'instruction' not in node:
                            errors.append(f"Conversation node '{node_id}' missing 'instruction' field")
                        else:
                            instruction = node['instruction']
                            if 'type' not in instruction:
                                errors.append(f"Node '{node_id}' instruction missing 'type' field")
                            if 'text' not in instruction:
                                errors.append(f"Node '{node_id}' instruction missing 'text' field")

                    elif node_type == 'function':
                        if 'function_name' not in node:
                            errors.append(f"Function node '{node_id}' missing 'function_name' field")

                        # Check if function exists in tools
                        if 'tools' in flow and 'function_name' in node:
                            tool_names = {tool.get('name') for tool in flow.get('tools', [])}
                            if node['function_name'] not in tool_names:
                                warnings.append(f"Function node '{node_id}' references function '{node['function_name']}' which is not defined in tools array")

                    elif node_type not in ['conversation', 'function', 'transfer', 'press_digit', 'logic', 'sms', 'extract_dynamic_variable', 'agent_transfer', 'mcp']:
                        warnings.append(f"Node '{node_id}' has unknown type '{node_type}'")

                # Check edges
                if 'edges' in node:
                    if not isinstance(node['edges'], list):
                        errors.append(f"Node '{node_id}' edges must be an array")
                    else:
                        for edge_idx, edge in enumerate(node['edges']):
                            if 'destination_node_id' not in edge:
                                errors.append(f"Node '{node_id}' edge {edge_idx} missing 'destination_node_id'")
                            else:
                                dest_id = edge['destination_node_id']
                                if dest_id not in node_ids:
                                    errors.append(f"Node '{node_id}' edge references non-existent node '{dest_id}'")

                            if 'transition_condition' in edge:
                                condition = edge['transition_condition']
                                if 'type' not in condition:
                                    errors.append(f"Node '{node_id}' edge {edge_idx} transition_condition missing 'type'")

    # Validate tools
    if 'tools' in flow:
        if not isinstance(flow['tools'], list):
            errors.append("'tools' must be an array")
        else:
            for idx, tool in enumerate(flow['tools']):
                tool_name = tool.get('name', f'<tool_index_{idx}>')

                # Check required tool fields
                required_tool_fields = ['name', 'description', 'url', 'method', 'parameters']
                for field in required_tool_fields:
                    if field not in tool:
                        errors.append(f"Tool '{tool_name}' missing required field '{field}'")

                # Validate parameters schema
                if 'parameters' in tool:
                    params = tool['parameters']
                    if 'type' not in params:
                        errors.append(f"Tool '{tool_name}' parameters missing 'type' field (must be 'object')")
                    elif params['type'] != 'object':
                        errors.append(f"Tool '{tool_name}' parameters type must be 'object', not '{params['type']}'")

    # Validate default_dynamic_variables (all values must be strings)
    if 'default_dynamic_variables' in flow:
        for var_name, var_value in flow['default_dynamic_variables'].items():
            if not isinstance(var_value, str):
                errors.append(f"Dynamic variable '{var_name}' has value of type {type(var_value).__name__}, must be string")

    # Print results
    print("\n" + "="*60)
    print("Retell AI Flow Validation Results")
    print("="*60)

    if errors:
        print(f"\n❌ {len(errors)} ERROR(S) FOUND:\n")
        for i, error in enumerate(errors, 1):
            print(f"  {i}. {error}")

    if warnings:
        print(f"\n⚠️  {len(warnings)} WARNING(S):\n")
        for i, warning in enumerate(warnings, 1):
            print(f"  {i}. {warning}")

    if not errors and not warnings:
        print("\n✅ ALL CHECKS PASSED!")
        print("\nFlow Summary:")
        print(f"  • Nodes: {len(flow.get('nodes', []))}")
        print(f"  • Tools: {len(flow.get('tools', []))}")
        print(f"  • Start Node: {flow.get('start_node_id')}")
        if 'default_dynamic_variables' in flow:
            print(f"  • Dynamic Variables: {len(flow['default_dynamic_variables'])}")

    print("\n" + "="*60 + "\n")

    return len(errors) == 0

if __name__ == "__main__":
    filepath = sys.argv[1] if len(sys.argv) > 1 else "retell_conversation_flow_v2.json"

    success = validate_retell_flow(filepath)
    sys.exit(0 if success else 1)
