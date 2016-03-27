"""
Interface to the config_lt_archive.xml file.  This class inherits from GenericXML.py
"""

from standard_module_setup import *
from generic_xml import GenericXML
from CIME.utils import expect

logger = logging.getLogger(__name__)

class LTArchive(GenericXML):

    def __init__(self, machine, infile=None):
        """
        initialize an object
        """
        if (infile is None):
            infile = os.path.join(get_cime_root(), "cime_config", get_model(), "machines", "config_lt_archive.xml")

        GenericXML.__init__(self, infile)

        self.machine = machine

    def get_lt_archive_args(self):
        """
        Return the lt archive args
        """
        nodes = self.get_nodes("machine")
        default = None
        for node in nodes:
            if node.attrib["name"] == self.machine:
                return self.get_node("lt_archive_args", root=node).text
            elif node.attrib["name"] == "default":
                default = self.get_node("lt_archive_args", root=node).text

        return default
